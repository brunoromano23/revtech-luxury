/**
 * Writes the durable log row from the published event.
 *
 * This runs in its own transaction, which is the entire point: the commit that produced the event
 * may already have rolled back (solution design 7.2).
 */
trigger CpqLogEventTrigger on CPQ_Log_Event__e(after insert) {
    List<CPQ_Integration_Log__c> logs = new List<CPQ_Integration_Log__c>();
    for (CPQ_Log_Event__e event : Trigger.new) {
        logs.add(
            new CPQ_Integration_Log__c(
                Correlation_Id__c = event.Correlation_Id__c,
                Endpoint__c = event.Endpoint__c,
                Acting_Rep__c = event.Acting_Rep__c,
                Integration_User__c = event.Integration_User__c,
                Opportunity_Id__c = event.Opportunity_Id__c,
                Outcome__c = event.Outcome__c,
                Violation_Codes__c = event.Violation_Codes__c,
                Duration_Ms__c = event.Duration_Ms__c,
                Message__c = event.Message__c,
                Stack_Trace__c = event.Stack_Trace__c,
                Logged_At__c = System.now()
            )
        );
    }
    // Partial success: one malformed event must not cost us the rest of the batch's logs.
    Database.insert(logs, false);
}
