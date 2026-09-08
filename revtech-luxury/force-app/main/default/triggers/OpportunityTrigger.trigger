/**
 * Single trigger per object, delegating to a handler class. Logic lives in Apex the tests can
 * call directly, not in the trigger body.
 */
trigger OpportunityTrigger on Opportunity(after update) {
    if (Trigger.isAfter && Trigger.isUpdate) {
        OpportunityCpqHandler.afterUpdate(Trigger.new, Trigger.oldMap);
    }
}
