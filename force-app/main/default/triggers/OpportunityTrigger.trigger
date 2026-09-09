/**
 * One trigger per object, and no logic in it. Which actions run, in what order, and whether they
 * are bypassed are Trigger_Action__mdt records rather than lines of code here — the same
 * configuration-over-deployment principle the catalog and Metering_Type__c already follow.
 */
trigger OpportunityTrigger on Opportunity(after update) {
    new MetadataTriggerHandler().run();
}
