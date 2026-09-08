/**
 * Commit semantics: atomicity, replacement, idempotency and refusal (R-13 through R-17).
 */
@IsTest
private class CpqCommitServiceTest {
    @TestSetup
    static void setup() {
        CpqTestData.seed();
    }

    private static List<OpportunityLineItem> linesOn(Id opportunityId) {
        return [
            SELECT Id, Quantity, UnitPrice, CPQ_Charge_Type__c, CPQ_Commit__c, CPQ_Catalog_Item__r.Code__c
            FROM OpportunityLineItem
            WHERE OpportunityId = :opportunityId
            ORDER BY CPQ_Catalog_Item__r.Code__c
        ];
    }

    // =====================================================================
    // The happy path
    // =====================================================================

    @IsTest
    static void commit_validConfiguration_createsPlanSetupFeeAndAddOnLines() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 500.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 2, 90.00);

        Test.startTest();
        CpqCommitService.Outcome outcome = CpqCommitService.commitConfiguration(opp.Id, request);
        Test.stopTest();

        Assert.isFalse(outcome.refused);
        List<OpportunityLineItem> lines = linesOn(opp.Id);
        Assert.areEqual(3, lines.size(), 'Plan, setup fee and one add-on line.');

        Map<String, OpportunityLineItem> byCode = new Map<String, OpportunityLineItem>();
        for (OpportunityLineItem line : lines) {
            byCode.put(line.CPQ_Catalog_Item__r.Code__c, line);
        }
        Assert.areEqual(500.00, byCode.get('PLAN_BRAND').UnitPrice, 'The negotiated price, not list.');
        Assert.areEqual(CpqConstants.CHARGE_RECURRING, byCode.get('PLAN_BRAND').CPQ_Charge_Type__c);
        Assert.areEqual(1000.00, byCode.get('SETUP_BRAND').UnitPrice);
        Assert.areEqual(CpqConstants.CHARGE_ONE_TIME, byCode.get('SETUP_BRAND').CPQ_Charge_Type__c);
        Assert.areEqual(2, byCode.get('ADDON_CONTACTS_500').Quantity, 'Stacking is quantity.');
        Assert.areEqual(90.00, byCode.get('ADDON_CONTACTS_500').UnitPrice);

        Opportunity reloaded = [
            SELECT Contract_Effective_Date__c, Contract_Term_Months__c, Contract_End_Date__c
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        Assert.areEqual(Date.today(), reloaded.Contract_Effective_Date__c);
        Assert.areEqual(12, reloaded.Contract_Term_Months__c);
        Assert.areEqual(
            Date.today().addMonths(12).addDays(-1),
            reloaded.Contract_End_Date__c,
            'End date is the last day covered by the term.'
        );

        Assert.areEqual(680.00, outcome.response.totals.monthlyRecurring, '500 plan + 2 x 90 contacts');
        Assert.areEqual(1000.00, outcome.response.totals.oneTime);
        Assert.areEqual(9160.00, outcome.response.totals.totalContractValue, '680 x 12 + 1000');
    }

    // =====================================================================
    // Refusal (R-13, R-14)
    // =====================================================================

    @IsTest
    static void commit_subFloorSkippingValidate_createsNothing() {
        // The client is not obliged to call /validate first, and may be a script that never does.
        // Commit re-runs the whole check itself, and refuses before writing anything.
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 400.00);

        Test.startTest();
        CpqCommitService.Outcome outcome = CpqCommitService.commitConfiguration(opp.Id, request);
        Test.stopTest();

        Assert.isTrue(outcome.refused, 'A sub-floor commit must be refused.');
        Assert.areEqual(CpqConstants.V_PLAN_BELOW_FLOOR, outcome.validation.violations[0].code);
        Assert.areEqual(0, linesOn(opp.Id).size(), 'Nothing may be written when the commit is refused.');
        Assert.areEqual(0, [SELECT COUNT() FROM CPQ_Commit__c], 'No commit record either.');
    }

    // =====================================================================
    // Replacement (R-16)
    // =====================================================================

    @IsTest
    static void commit_secondCommit_replacesPriorCpqLinesOnly() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest first = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqTestData.withAddOn(first, CpqTestData.CONTACTS, 1, 100.00);
        CpqCommitService.commitConfiguration(opp.Id, first);
        Assert.areEqual(3, linesOn(opp.Id).size());

        // Re-quoting is the normal case. Appending would double-bill and double-entitle.
        CpqDto.ConfigurationRequest second = CpqTestData.request(CpqTestData.ALL_IN, 2200.00);

        Test.startTest();
        CpqCommitService.commitConfiguration(opp.Id, second);
        Test.stopTest();

        List<OpportunityLineItem> lines = linesOn(opp.Id);
        Assert.areEqual(2, lines.size(), 'Prior CPQ lines are replaced, not appended to.');
        Assert.areEqual('PLAN_ALL_IN', lines[0].CPQ_Catalog_Item__r.Code__c);
        Assert.areEqual('SETUP_ALL_IN', lines[1].CPQ_Catalog_Item__r.Code__c);

        Assert.areEqual(1, [SELECT COUNT() FROM CPQ_Commit__c WHERE Status__c = 'Committed']);
        Assert.areEqual(1, [SELECT COUNT() FROM CPQ_Commit__c WHERE Status__c = 'Superseded']);
    }

    @IsTest
    static void commit_manuallyAddedLine_survivesRecommit() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqCommitService.commitConfiguration(opp.Id, CpqTestData.request(CpqTestData.BRAND, 595.00));

        // Something else on the Opportunity: a professional-services line added by hand, an
        // integration from another team. It is not ours and we must not delete it.
        Map<String, CPQ_Catalog_Item__c> items = CpqTestData.itemsByCode();
        Map<Id, Id> entries = CpqTestData.pricebookEntriesByProduct();
        insert new OpportunityLineItem(
            OpportunityId = opp.Id,
            PricebookEntryId = entries.get(items.get(CpqTestData.DESIGN_REFRESH).Product__c),
            Quantity = 1,
            UnitPrice = 999.00
        );
        Assert.areEqual(3, linesOn(opp.Id).size());

        Test.startTest();
        CpqCommitService.commitConfiguration(opp.Id, CpqTestData.request(CpqTestData.LAUNCH, 295.00));
        Test.stopTest();

        List<OpportunityLineItem> remaining = linesOn(opp.Id);
        Assert.areEqual(3, remaining.size(), 'Two new CPQ lines plus the untouched manual line.');

        Integer manual = 0;
        for (OpportunityLineItem line : remaining) {
            if (line.CPQ_Commit__c == null) {
                manual++;
                Assert.areEqual(999.00, line.UnitPrice);
            }
        }
        Assert.areEqual(1, manual, 'The hand-added line must survive a re-commit.');
    }

    // =====================================================================
    // Idempotency (R-17)
    // =====================================================================

    @IsTest
    static void commit_sameIdempotencyKeyTwice_createsOneSetAndReplaysResult() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);

        Test.startTest();
        CpqCommitService.Outcome first = CpqCommitService.commitConfiguration(opp.Id, request);
        // A network timeout on the client and a retry: the same key, the same payload.
        CpqCommitService.Outcome second = CpqCommitService.commitConfiguration(opp.Id, request);
        Test.stopTest();

        Assert.isFalse(first.response.replayed);
        Assert.isTrue(second.response.replayed, 'The retry must be flagged as a replay.');
        Assert.areEqual(first.response.commitId, second.response.commitId, 'Same commit, replayed verbatim.');
        Assert.areEqual(2, linesOn(opp.Id).size(), 'A retry must not double-write.');
        Assert.areEqual(1, [SELECT COUNT() FROM CPQ_Commit__c]);
    }

    @IsTest
    static void commit_idempotencyKeyReusedWithDifferentPayload_isConflict() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqCommitService.commitConfiguration(opp.Id, request);

        // Replaying would return a result for a payload the caller did not send; committing would
        // silently overwrite. Neither is safe.
        CpqDto.ConfigurationRequest changed = CpqTestData.request(CpqTestData.BRAND, 500.00);
        changed.idempotencyKey = request.idempotencyKey;

        Test.startTest();
        try {
            CpqCommitService.commitConfiguration(opp.Id, changed);
            Assert.fail('Reusing a key for a different configuration must conflict.');
        } catch (CpqException e) {
            Assert.areEqual(409, e.statusCode);
            Assert.areEqual('IDEMPOTENCY_KEY_REUSED', e.errorCode);
        }
        Test.stopTest();
    }

    // =====================================================================
    // Guards (R-15)
    // =====================================================================

    @IsTest
    static void commit_closedOpportunity_rejectedWith409() {
        Opportunity opp = CpqTestData.newOpportunity();
        OpportunityCpqHandler.disabled = true;
        opp.StageName = 'Closed Won';
        update opp;
        OpportunityCpqHandler.disabled = false;

        Test.startTest();
        try {
            CpqCommitService.commitConfiguration(opp.Id, CpqTestData.request(CpqTestData.BRAND, 595.00));
            Assert.fail('A closed Opportunity is immutable to this API.');
        } catch (CpqException e) {
            Assert.areEqual(409, e.statusCode);
            Assert.areEqual('OPPORTUNITY_CLOSED', e.errorCode);
        }
        Test.stopTest();
    }

    @IsTest
    static void commit_unknownOpportunityId_isNotFound() {
        // A well-formed Id for a record that does not exist, or that the caller cannot see. Both
        // answer 404, so the endpoint cannot be used to probe which Ids exist.
        Id absent = '006000000000000AAA';
        try {
            CpqCommitService.commitConfiguration(absent, CpqTestData.request(CpqTestData.BRAND, 595.00));
            Assert.fail('Expected a not-found.');
        } catch (CpqException e) {
            Assert.areEqual(404, e.statusCode);
        }
    }

    @IsTest
    static void commit_unresolvableActingRep_isRejected() {
        // Attribution is required, not optional: an unattributable discount defeats the point of
        // enforcing a floor at all.
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        request.actingRepEmail = 'nobody@nowhere.invalid';

        try {
            CpqCommitService.commitConfiguration(opp.Id, request);
            Assert.fail('Expected the unknown rep to be rejected.');
        } catch (CpqException e) {
            Assert.areEqual('UNKNOWN_ACTING_REP', e.errorCode);
        }
        Assert.areEqual(0, linesOn(opp.Id).size(), 'The savepoint must have rolled the commit record back.');
    }

    @IsTest
    static void commit_opportunityWithoutAccount_isRejected() {
        Opportunity orphan = new Opportunity(
            Name = 'No account',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert orphan;

        try {
            CpqCommitService.commitConfiguration(orphan.Id, CpqTestData.request(CpqTestData.BRAND, 595.00));
            Assert.fail('Expected rejection: entitlements are held against a customer.');
        } catch (CpqException e) {
            Assert.areEqual('OPPORTUNITY_HAS_NO_ACCOUNT', e.errorCode);
        }
    }
}
