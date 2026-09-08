/**
 * Closed Won automation (solution design 8). Apex rather than a Record-Triggered Flow, as the
 * brief requires.
 *
 * Entitlements are created synchronously so the subscription, the entitlements and the won stage
 * share one transaction: a deal cannot be won carrying half-built entitlements. If entitlement
 * creation ever needs a callout this moves to a Queueable and the guarantee weakens from
 * transactional to eventually consistent — worth doing deliberately, not by accident.
 */
public with sharing class OpportunityCpqHandler {
    /** Set true by tests that need to exercise the trigger's own guards without recursion. */
    @TestVisible
    private static Boolean disabled = false;

    public static void afterUpdate(List<Opportunity> updated, Map<Id, Opportunity> previous) {
        if (disabled) {
            return;
        }

        // Fire on the transition into Closed Won only. Re-saving a won Opportunity, or editing a
        // deal that closed last quarter, must not regenerate anything (R-20).
        Set<Id> newlyWon = new Set<Id>();
        for (Opportunity opp : updated) {
            Opportunity before = previous.get(opp.Id);
            if (opp.IsWon == true && (before == null || before.IsWon != true)) {
                newlyWon.add(opp.Id);
            }
        }
        if (newlyWon.isEmpty()) {
            return;
        }

        Map<Id, String> failures;
        try {
            failures = CpqEntitlementService.generate(newlyWon);
        } catch (Exception e) {
            // Log through the event bus so the record survives the rollback addError causes,
            // then fail the batch loudly rather than swallowing it.
            CpqLogger.error(null, 'trigger:Opportunity.ClosedWon', null, null, e);
            for (Opportunity opp : updated) {
                if (newlyWon.contains(opp.Id)) {
                    opp.addError('Entitlement provisioning failed: ' + e.getMessage());
                }
            }
            return;
        }

        if (failures.isEmpty()) {
            return;
        }

        // Fail only the Opportunities that actually failed; the other 199 in the batch still close.
        for (Opportunity opp : updated) {
            String reason = failures.get(opp.Id);
            if (reason != null) {
                CpqLogger.rejected(null, 'trigger:Opportunity.ClosedWon', null, opp.Id, reason);
                opp.addError('Entitlement provisioning failed: ' + reason);
            }
        }
    }
}
