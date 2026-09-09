/**
 * Binds the Closed Won automation to the Trigger Actions Framework.
 *
 * Deliberately thin. The framework's job is deciding *whether and in what order* something runs;
 * this class translates its call shape into the handler's and does nothing else. Keeping the
 * business logic in OpportunityCpqHandler means the entitlement tests still call plain Apex and
 * never construct trigger context, and the framework stays a routing concern rather than something
 * the domain logic is coupled to.
 *
 * Registered against Opportunity / After Update in Trigger_Action__mdt. Adding the renewal and
 * amendment actions this design anticipates (S9) is a metadata record and a class, with the
 * execution order set by Order__c rather than by editing a trigger body.
 */
public with sharing class OpportunityCpqEntitlementAction implements TriggerAction.AfterUpdate {
    public void afterUpdate(List<Opportunity> newList, List<Opportunity> oldList) {
        // The framework hands over parallel lists; the handler reasons about the transition into
        // Closed Won, which reads far better against a map keyed by Id.
        Map<Id, Opportunity> previous = new Map<Id, Opportunity>();
        if (oldList != null) {
            for (Opportunity old : oldList) {
                previous.put(old.Id, old);
            }
        }
        OpportunityCpqHandler.afterUpdate(newList, previous);
    }
}
