/**
 * Turns won Opportunities into durable subscription and entitlement records.
 *
 * Bulk-safe by construction: every query and every DML sits outside all loops, so the cost is the
 * same for one Opportunity as for a 200-record Data Loader stage update. The common path is two
 * SOQL and two DML; regenerating over an existing subscription costs one more of each, and only
 * then (R-20).
 *
 * The aggregation itself is the interesting part. Plan inclusions and add-ons both contribute
 * through the same path — neither is privileged, the plan is not "the base" that add-ons top up —
 * which is what makes the overlap work in both directions the brief asks for (R-18).
 */
public with sharing class CpqEntitlementService {
    /** Running total for one feature on one Opportunity. */
    private class Accrual {
        Id featureId;
        String featureCode;
        String meteringType;
        Decimal quantity;

        Accrual(Id featureId, String featureCode, String meteringType) {
            this.featureId = featureId;
            this.featureCode = featureCode;
            this.meteringType = meteringType;
        }

        /**
         * Metered features sum; binary features record presence and stay null. Which of the two
         * happens is a field on CPQ_Feature__c, not a branch on a product code, so a new metered
         * feature needs no deployment here.
         */
        void add(Decimal amount) {
            if (meteringType != CpqConstants.METERING_METERED) {
                return;
            }
            quantity = (quantity == null ? 0 : quantity) + (amount == null ? 0 : amount);
        }
    }

    /** Per-Opportunity working set, so nothing has to be re-derived in a second pass. */
    private class Rollup {
        Id opportunityId;
        Id accountId;
        Date effectiveDate;
        Integer termMonths;
        Id planItemId;
        String planCode;
        Decimal monthlyRecurring = 0;
        Decimal oneTime = 0;
        Map<Id, Accrual> accrualsByFeature = new Map<Id, Accrual>();

        Accrual accrual(Id featureId, String code, String metering) {
            Accrual found = accrualsByFeature.get(featureId);
            if (found == null) {
                found = new Accrual(featureId, code, metering);
                accrualsByFeature.put(featureId, found);
            }
            return found;
        }
    }

    /**
     * @return the Opportunity Ids that could not be provisioned, so the trigger can fail exactly
     *         those records and let the rest of the batch succeed.
     */
    public static Map<Id, String> generate(Set<Id> opportunityIds) {
        Map<Id, String> failures = new Map<Id, String>();
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return failures;
        }

        // SOQL 1. Everything the rollup needs, including the Opportunity's own contract fields,
        // reached through the line item so this stays a single query.
        List<OpportunityLineItem> lines = [
            SELECT
                Id,
                OpportunityId,
                Quantity,
                UnitPrice,
                TotalPrice,
                CPQ_Charge_Type__c,
                CPQ_Catalog_Item__c,
                CPQ_Catalog_Item__r.Code__c,
                CPQ_Catalog_Item__r.Item_Type__c,
                CPQ_Catalog_Item__r.Charge_Type__c,
                CPQ_Catalog_Item__r.Feature__c,
                CPQ_Catalog_Item__r.Feature__r.Code__c,
                CPQ_Catalog_Item__r.Feature__r.Metering_Type__c,
                CPQ_Catalog_Item__r.Feature_Quantity_Per_Unit__c,
                Opportunity.AccountId,
                Opportunity.Contract_Effective_Date__c,
                Opportunity.Contract_Term_Months__c
            FROM OpportunityLineItem
            WHERE OpportunityId IN :opportunityIds AND CPQ_Catalog_Item__c != NULL
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return failures;
        }

        Map<Id, Rollup> rollups = new Map<Id, Rollup>();
        Set<Id> planItemIds = new Set<Id>();

        for (OpportunityLineItem line : lines) {
            Rollup rollup = rollups.get(line.OpportunityId);
            if (rollup == null) {
                rollup = new Rollup();
                rollup.opportunityId = line.OpportunityId;
                rollup.accountId = line.Opportunity.AccountId;
                rollup.effectiveDate = line.Opportunity.Contract_Effective_Date__c;
                rollup.termMonths = line.Opportunity.Contract_Term_Months__c == null
                    ? null
                    : Integer.valueOf(line.Opportunity.Contract_Term_Months__c);
                rollups.put(line.OpportunityId, rollup);
            }

            if (line.CPQ_Catalog_Item__r.Charge_Type__c == CpqConstants.CHARGE_RECURRING) {
                rollup.monthlyRecurring += line.TotalPrice == null ? 0 : line.TotalPrice;
            } else {
                rollup.oneTime += line.TotalPrice == null ? 0 : line.TotalPrice;
            }

            if (line.CPQ_Catalog_Item__r.Item_Type__c == CpqConstants.TYPE_PLAN) {
                rollup.planItemId = line.CPQ_Catalog_Item__c;
                rollup.planCode = line.CPQ_Catalog_Item__r.Code__c;
                planItemIds.add(line.CPQ_Catalog_Item__c);
                continue;
            }

            // R-19. Setup fees and one-time services are billable and grant nothing. Design Refresh
            // falls out here too, but by way of a null Feature__c rather than by being named.
            if (
                line.CPQ_Catalog_Item__r.Item_Type__c == CpqConstants.TYPE_SETUP_FEE ||
                line.CPQ_Catalog_Item__r.Charge_Type__c != CpqConstants.CHARGE_RECURRING ||
                line.CPQ_Catalog_Item__r.Feature__c == null
            ) {
                continue;
            }

            Decimal perUnit = line.CPQ_Catalog_Item__r.Feature_Quantity_Per_Unit__c;
            Decimal quantity = line.Quantity == null ? 0 : line.Quantity;
            rollup.accrual(
                    line.CPQ_Catalog_Item__r.Feature__c,
                    line.CPQ_Catalog_Item__r.Feature__r.Code__c,
                    line.CPQ_Catalog_Item__r.Feature__r.Metering_Type__c
                )
                .add(perUnit == null ? null : perUnit * quantity);
        }

        // SOQL 2. What each plan includes, and how much of it.
        if (!planItemIds.isEmpty()) {
            List<CPQ_Plan_Feature__c> inclusions = [
                SELECT Plan__c, Feature__c, Feature__r.Code__c, Feature__r.Metering_Type__c, Quantity__c
                FROM CPQ_Plan_Feature__c
                WHERE Plan__c IN :planItemIds
                WITH USER_MODE
            ];
            Map<Id, List<CPQ_Plan_Feature__c>> byPlan = new Map<Id, List<CPQ_Plan_Feature__c>>();
            for (CPQ_Plan_Feature__c inclusion : inclusions) {
                if (!byPlan.containsKey(inclusion.Plan__c)) {
                    byPlan.put(inclusion.Plan__c, new List<CPQ_Plan_Feature__c>());
                }
                byPlan.get(inclusion.Plan__c).add(inclusion);
            }
            for (Rollup rollup : rollups.values()) {
                if (rollup.planItemId == null) {
                    continue;
                }
                List<CPQ_Plan_Feature__c> included = byPlan.get(rollup.planItemId);
                if (included == null) {
                    continue;
                }
                for (CPQ_Plan_Feature__c inclusion : included) {
                    rollup.accrual(
                            inclusion.Feature__c,
                            inclusion.Feature__r.Code__c,
                            inclusion.Feature__r.Metering_Type__c
                        )
                        .add(inclusion.Quantity__c);
                }
            }
        }

        return persist(rollups, failures);
    }

    // =====================================================================
    // Persistence
    // =====================================================================

    private static Map<Id, String> persist(Map<Id, Rollup> rollups, Map<Id, String> failures) {
        List<Subscription__c> subscriptions = new List<Subscription__c>();
        List<Id> orderedOppIds = new List<Id>();

        for (Rollup rollup : rollups.values()) {
            if (rollup.accountId == null) {
                failures.put(rollup.opportunityId, 'Opportunity has no Account, so no entitlements can be created.');
                continue;
            }
            Date endDate = (rollup.effectiveDate == null || rollup.termMonths == null)
                ? null
                : rollup.effectiveDate.addMonths(rollup.termMonths).addDays(-1);

            subscriptions.add(
                new Subscription__c(
                    External_Key__c = String.valueOf(rollup.opportunityId),
                    Account__c = rollup.accountId,
                    Opportunity__c = rollup.opportunityId,
                    Plan__c = rollup.planItemId,
                    Plan_Code__c = rollup.planCode,
                    Effective_Date__c = rollup.effectiveDate,
                    Term_Months__c = rollup.termMonths,
                    End_Date__c = endDate,
                    Monthly_Recurring_Revenue__c = rollup.monthlyRecurring.setScale(2),
                    One_Time_Total__c = rollup.oneTime.setScale(2),
                    Status__c = 'Active'
                )
            );
            orderedOppIds.add(rollup.opportunityId);
        }
        if (subscriptions.isEmpty()) {
            return failures;
        }

        // DML 1. Upsert on the unique External Id, so a second run over the same Opportunity
        // updates rather than duplicates even if a future entry point bypasses the trigger guard.
        List<Database.UpsertResult> results = Database.upsert(
            subscriptions,
            Subscription__c.External_Key__c,
            false,
            AccessLevel.USER_MODE
        );

        Set<Id> preExisting = new Set<Id>();
        Map<Id, Id> subscriptionByOpp = new Map<Id, Id>();
        for (Integer i = 0; i < results.size(); i++) {
            Id oppId = orderedOppIds[i];
            if (!results[i].isSuccess()) {
                failures.put(oppId, firstError(results[i]));
                continue;
            }
            subscriptionByOpp.put(oppId, results[i].getId());
            if (!results[i].isCreated()) {
                preExisting.add(results[i].getId());
            }
        }

        // R-21. Only when a subscription already existed do we pay for the extra query, and even
        // then history is superseded rather than overwritten — a billing dispute six months later
        // needs to see what the customer was entitled to at the time.
        if (!preExisting.isEmpty()) {
            List<Customer_Entitlement__c> stale = [
                SELECT Id
                FROM Customer_Entitlement__c
                WHERE Subscription__c IN :preExisting AND Status__c = 'Active'
                WITH USER_MODE
            ];
            for (Customer_Entitlement__c entitlement : stale) {
                entitlement.Status__c = 'Superseded';
                entitlement.Active_To__c = Date.today();
            }
            if (!stale.isEmpty()) {
                Database.update(stale, false, AccessLevel.USER_MODE);
            }
        }

        List<Customer_Entitlement__c> entitlements = new List<Customer_Entitlement__c>();
        for (Rollup rollup : rollups.values()) {
            Id subscriptionId = subscriptionByOpp.get(rollup.opportunityId);
            if (subscriptionId == null) {
                continue;
            }
            Date endDate = (rollup.effectiveDate == null || rollup.termMonths == null)
                ? null
                : rollup.effectiveDate.addMonths(rollup.termMonths).addDays(-1);

            for (Accrual accrual : rollup.accrualsByFeature.values()) {
                entitlements.add(
                    new Customer_Entitlement__c(
                        Subscription__c = subscriptionId,
                        Feature__c = accrual.featureId,
                        Feature_Code__c = accrual.featureCode,
                        Quantity__c = accrual.quantity,
                        Metering_Type__c = accrual.meteringType,
                        Active_From__c = rollup.effectiveDate,
                        Active_To__c = endDate,
                        Status__c = 'Active',
                        Source_Opportunity__c = rollup.opportunityId
                    )
                );
            }
        }

        // DML 2.
        if (!entitlements.isEmpty()) {
            Database.insert(entitlements, false, AccessLevel.USER_MODE);
        }
        return failures;
    }

    private static String firstError(Database.UpsertResult result) {
        List<Database.Error> errors = result.getErrors();
        return errors.isEmpty() ? 'Unknown error' : errors[0].getMessage();
    }
}
