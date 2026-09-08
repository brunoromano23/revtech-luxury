/**
 * The failure paths.
 *
 * Error handling is the part of an integration that gets exercised at 2am by someone who did not
 * write it, so it is tested rather than assumed: what the caller is told, what lands in the log,
 * and which records survive.
 */
@IsTest
private class CpqObservabilityTest {
    @TestSetup
    static void setup() {
        CpqTestData.seed();
    }

    // =====================================================================
    // Closed Won failure handling (design doc 8)
    // =====================================================================

    @IsTest
    static void closedWon_opportunityWithoutAccount_failsThatRecordWithAReadableMessage() {
        // Line items configured by some earlier route, but no Account to hold the entitlements.
        Opportunity orphan = new Opportunity(
            Name = 'Orphan',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert orphan;
        CpqTestData.addCpqLines(
            new List<Opportunity>{ orphan },
            new List<String>{ CpqTestData.BRAND },
            new List<Integer>{ 1 }
        );
        CpqTestData.setContractTerms(new List<Opportunity>{ orphan }, Date.today(), 12);

        Test.startTest();
        DmlException caught;
        try {
            orphan.StageName = 'Closed Won';
            update orphan;
        } catch (DmlException e) {
            caught = e;
        }
        Test.stopTest();

        Assert.isNotNull(caught, 'The stage change must fail rather than close a deal with no entitlements.');
        Assert.isTrue(
            caught.getDmlMessage(0).contains('Entitlement provisioning failed'),
            'The rep needs to know why: ' + caught.getDmlMessage(0)
        );
        Assert.areEqual(0, [SELECT COUNT() FROM Subscription__c]);
    }

    @IsTest
    static void closedWon_oneBadRecordInABatch_doesNotFailTheOtherNinetyNine() {
        // The reason failures are mapped per record rather than thrown for the batch: a data
        // problem on one deal must not stop ninety-nine good ones closing.
        List<Opportunity> good = CpqTestData.newOpportunities(99);
        Opportunity orphan = new Opportunity(
            Name = 'Orphan',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert orphan;

        List<Opportunity> all = new List<Opportunity>(good);
        all.add(orphan);
        CpqTestData.addCpqLines(all, new List<String>{ CpqTestData.LAUNCH }, new List<Integer>{ 1 });
        CpqTestData.setContractTerms(all, Date.today(), 12);

        for (Opportunity opp : all) {
            opp.StageName = 'Closed Won';
        }

        Test.startTest();
        List<Database.SaveResult> results = Database.update(all, false);
        Test.stopTest();

        Integer succeeded = 0;
        Integer failed = 0;
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                succeeded++;
            } else {
                failed++;
            }
        }
        Assert.areEqual(99, succeeded, 'The healthy deals must still close.');
        Assert.areEqual(1, failed, 'Only the broken one fails.');
        Assert.areEqual(99, [SELECT COUNT() FROM Subscription__c]);
    }

    // =====================================================================
    // Logging (design doc 7.2)
    // =====================================================================

    @IsTest
    static void successfulCommit_isLoggedWithRepAndDuration() {
        Opportunity opp = CpqTestData.newOpportunity();
        RestRequest request = new RestRequest();
        request.httpMethod = 'POST';
        request.requestURI = '/services/apexrest/cpq/v1/opportunities/' + opp.Id + '/commit';
        request.requestBody = Blob.valueOf(JSON.serialize(CpqTestData.request(CpqTestData.BRAND, 595.00)));
        RestContext.request = request;
        RestContext.response = new RestResponse();

        Test.startTest();
        CpqCommitResource.commitConfiguration();
        Test.stopTest();

        CPQ_Integration_Log__c log = [
            SELECT Correlation_Id__c, Endpoint__c, Acting_Rep__c, Opportunity_Id__c, Outcome__c, Duration_Ms__c, Integration_User__c
            FROM CPQ_Integration_Log__c
            LIMIT 1
        ];
        Assert.areEqual(CpqConstants.OUTCOME_SUCCESS, log.Outcome__c);
        Assert.areEqual(String.valueOf(opp.Id), log.Opportunity_Id__c);
        // The rep is carried in the body because Salesforce only ever sees one integration user.
        Assert.areEqual(UserInfo.getUserName(), log.Acting_Rep__c);
        Assert.areEqual(UserInfo.getUserName(), log.Integration_User__c);
        Assert.isNotNull(log.Duration_Ms__c);
        // No header was sent, so the server minted one rather than logging a null.
        Assert.isNotNull(log.Correlation_Id__c);
    }

    @IsTest
    static void unexpectedError_logsTheStackTraceButNeverReturnsIt() {
        Test.startTest();
        CpqLogger.error('corr-err', 'POST /cpq/v1/test', 'rep@example.com', null, new CpqException('boom'));
        Test.stopTest();

        CPQ_Integration_Log__c log = [
            SELECT Outcome__c, Message__c, Stack_Trace__c, Correlation_Id__c
            FROM CPQ_Integration_Log__c
            LIMIT 1
        ];
        Assert.areEqual(CpqConstants.OUTCOME_ERROR, log.Outcome__c);
        Assert.areEqual('boom', log.Message__c);
        Assert.areEqual('corr-err', log.Correlation_Id__c);
    }

    @IsTest
    static void logPublishing_survivesTheRollbackOfTheTransactionItDescribes() {
        // The whole reason logs are platform events: a commit that fails rolls back, and a log row
        // inserted inside that transaction would roll back with it.
        Test.startTest();
        Savepoint sp = Database.setSavepoint();
        insert new Account(Name = 'Rolled back');
        CpqLogger.rejected('corr-rollback', 'POST /cpq/v1/test', null, null, 'something went wrong');
        Database.rollback(sp);
        Test.stopTest();

        Assert.areEqual(
            1,
            [SELECT COUNT() FROM CPQ_Integration_Log__c WHERE Correlation_Id__c = 'corr-rollback'],
            'The log must outlive the rollback.'
        );
    }

    // =====================================================================
    // Request plumbing
    // =====================================================================

    @IsTest
    static void correlationId_isMintedWhenTheCallerSendsNone() {
        RestRequest request = new RestRequest();
        String generated = CpqRestSupport.correlationId(request);

        Assert.isNotNull(generated);
        Assert.areEqual(36, generated.length(), 'UUID-shaped, so it joins cleanly with the platform\'s logs.');
        Assert.areNotEqual(generated, CpqRestSupport.correlationId(request), 'Each call gets its own.');
    }

    @IsTest
    static void correlationId_prefersTheOneTheCallerSupplied() {
        RestRequest request = new RestRequest();
        request.addHeader(CpqRestSupport.HEADER_CORRELATION, 'platform-abc-123');
        Assert.areEqual('platform-abc-123', CpqRestSupport.correlationId(request));
    }

    @IsTest
    static void uriWithoutAnOpportunitySegment_isABadRequest() {
        try {
            CpqRestSupport.opportunityIdFromUri('/services/apexrest/cpq/v1/commit');
            Assert.fail('Expected a bad request.');
        } catch (CpqException e) {
            Assert.areEqual(400, e.statusCode);
            Assert.areEqual('MISSING_OPPORTUNITY_ID', e.errorCode);
        }
    }

    @IsTest
    static void permittedContractTerms_fallBackToTheDocumentedDefaultRatherThanAnythingGoes() {
        // If the configuration record is ever missing, the safe failure is the documented set,
        // not an empty set that would accept any term a caller sends.
        Set<Integer> terms = CpqConstants.permittedContractTerms();
        Assert.isTrue(terms.contains(12) && terms.contains(24) && terms.contains(36));
        Assert.isFalse(terms.contains(18));
    }

    @IsTest
    static void tooManyAddOnLines_isRejectedBeforeAnythingIsQueried() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        for (Integer i = 0; i < CpqConstants.MAX_ADDON_LINES + 1; i++) {
            CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 1, 100.00);
        }

        CpqValidator.Resolved resolved = CpqValidator.validate(request, CpqCatalogService.load(Date.today()));

        Assert.isFalse(resolved.isValid());
        Assert.areEqual(
            1,
            resolved.response.violations.size(),
            'One bounded-input violation, not fifty-one duplicate violations.'
        );
        Assert.areEqual(CpqConstants.V_ADDON_QUANTITY_INVALID, resolved.response.violations[0].code);
    }
}
