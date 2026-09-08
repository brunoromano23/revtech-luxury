/**
 * Closed Won automation and the entitlement aggregation (R-18 through R-21).
 *
 * The overlap between plan-included features and add-ons is the part of the brief most likely to
 * be got wrong, so it is asserted in both directions and at more than one quantity.
 */
@IsTest
private class CpqEntitlementServiceTest {
    @TestSetup
    static void setup() {
        CpqTestData.seed();
    }

    private static Opportunity close(Opportunity opp) {
        opp.StageName = 'Closed Won';
        update opp;
        return opp;
    }

    // =====================================================================
    // The case the brief calls out (R-18)
    // =====================================================================

    @IsTest
    static void closedWon_brandPlusContacts500_entitlesOneThousandContacts() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 1, 100.00);
        CpqCommitService.commitConfiguration(opp.Id, request);

        Test.startTest();
        close(opp);
        Test.stopTest();

        Subscription__c subscription = [
            SELECT Account__c, Plan_Code__c, Effective_Date__c, Term_Months__c, End_Date__c, Monthly_Recurring_Revenue__c, One_Time_Total__c
            FROM Subscription__c
            WHERE Opportunity__c = :opp.Id
        ];
        Assert.areEqual('PLAN_BRAND', subscription.Plan_Code__c);
        Assert.areEqual(695.00, subscription.Monthly_Recurring_Revenue__c, '595 plan + 100 contacts');
        Assert.areEqual(1000.00, subscription.One_Time_Total__c, 'The setup fee, kept separate for billing.');
        Assert.areEqual(Date.today().addMonths(12).addDays(-1), subscription.End_Date__c);

        Map<String, Customer_Entitlement__c> entitlements = CpqTestData.entitlementsByFeature(opp.Id);
        Assert.areEqual(3, entitlements.size(), 'Hosting, feeds and contacts.');

        // 500 from the Brand plan's included contact pack, plus 500 from the add-on.
        Assert.areEqual(
            1000,
            entitlements.get('FEAT_CONTACTS').Quantity__c.intValue(),
            'Plan-included and add-on contacts must combine.'
        );
        Assert.areEqual(CpqConstants.METERING_METERED, entitlements.get('FEAT_CONTACTS').Metering_Type__c);

        // Binary features carry no quantity: "has hosting" is the whole statement.
        Assert.isNull(entitlements.get('FEAT_WEBSITE_HOSTING').Quantity__c);
        Assert.areEqual(Date.today(), entitlements.get('FEAT_CONTACTS').Active_From__c);
        Assert.areEqual(Date.today().addMonths(12).addDays(-1), entitlements.get('FEAT_CONTACTS').Active_To__c);
    }

    @IsTest
    static void closedWon_allInWithCompetitorAnalysisAddOn_entitlesOnceNotTwice() {
        // All In already includes Competitor Analysis. Buying it again is legal (the brief says the
        // overlap works both ways) and must resolve to enabled once, because the feature is Binary.
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.ALL_IN, 2495.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 3, 100.00);
        CpqTestData.withAddOn(request, CpqTestData.COMPETITOR, 1, 150.00);
        CpqCommitService.commitConfiguration(opp.Id, request);

        Test.startTest();
        close(opp);
        Test.stopTest();

        Map<String, Customer_Entitlement__c> entitlements = CpqTestData.entitlementsByFeature(opp.Id);

        Assert.areEqual(1, [SELECT COUNT() FROM Customer_Entitlement__c WHERE Feature_Code__c = 'FEAT_COMPETITOR_ANALYSIS'], 'Enabled once, not twice.');
        Assert.isNull(entitlements.get('FEAT_COMPETITOR_ANALYSIS').Quantity__c, 'A binary feature does not accumulate.');

        // 1,000 from All In's contact pack x2, plus 3 x 500 from the add-on.
        Assert.areEqual(2500, entitlements.get('FEAT_CONTACTS').Quantity__c.intValue(), '1000 + 1500');
    }

    // =====================================================================
    // Billable but non-entitling (R-19)
    // =====================================================================

    @IsTest
    static void closedWon_designRefresh_billableWithNoEntitlement() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.LAUNCH, 295.00);
        CpqTestData.withAddOn(request, CpqTestData.DESIGN_REFRESH, 1, 750.00);
        CpqCommitService.commitConfiguration(opp.Id, request);

        Test.startTest();
        close(opp);
        Test.stopTest();

        // It must reach billing...
        Subscription__c subscription = [SELECT One_Time_Total__c FROM Subscription__c WHERE Opportunity__c = :opp.Id];
        Assert.areEqual(1250.00, subscription.One_Time_Total__c, '500 setup fee + 750 design refresh');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId = :opp.Id AND CPQ_Catalog_Item__r.Code__c = :CpqTestData.DESIGN_REFRESH]
        );

        // ...and must never reach feature gating. Not because it is named anywhere in the code,
        // but because its Feature__c is null.
        Map<String, Customer_Entitlement__c> entitlements = CpqTestData.entitlementsByFeature(opp.Id);
        Assert.areEqual(2, entitlements.size(), 'Launch grants hosting and feeds, and nothing else.');
        Assert.isTrue(entitlements.containsKey('FEAT_WEBSITE_HOSTING'));
        Assert.isTrue(entitlements.containsKey('FEAT_LISTING_FEEDS'));
    }

    @IsTest
    static void closedWon_setupFee_producesNoEntitlement() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqCommitService.commitConfiguration(opp.Id, CpqTestData.request(CpqTestData.BRAND, 595.00));

        Test.startTest();
        close(opp);
        Test.stopTest();

        for (Customer_Entitlement__c entitlement : [SELECT Feature_Code__c FROM Customer_Entitlement__c]) {
            Assert.isTrue(entitlement.Feature_Code__c.startsWith('FEAT_'), 'A setup fee is not a capability.');
        }
        Assert.areEqual(1000.00, [SELECT One_Time_Total__c FROM Subscription__c LIMIT 1].One_Time_Total__c);
    }

    // =====================================================================
    // Bulk and idempotency (R-20)
    // =====================================================================

    @IsTest
    static void closedWon_bulk200Opportunities_withinGovernorLimits() {
        List<Opportunity> opps = CpqTestData.newOpportunities(200);
        CpqTestData.addCpqLines(
            opps,
            new List<String>{ CpqTestData.BRAND, 'SETUP_BRAND', CpqTestData.CONTACTS },
            new List<Integer>{ 1, 1, 2 }
        );
        CpqTestData.setContractTerms(opps, Date.today(), 12);

        for (Opportunity opp : opps) {
            opp.StageName = 'Closed Won';
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        update opps;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Subscription__c], 'One subscription per won deal.');
        // 200 deals x (hosting, feeds, contacts)
        Assert.areEqual(600, [SELECT COUNT() FROM Customer_Entitlement__c]);

        // 500 from the plan's pack, plus 2 x 500 from the add-on.
        for (Customer_Entitlement__c entitlement : [
            SELECT Quantity__c
            FROM Customer_Entitlement__c
            WHERE Feature_Code__c = 'FEAT_CONTACTS'
        ]) {
            Assert.areEqual(1500, entitlement.Quantity__c.intValue());
        }

        // The point of the test: cost is flat, not per-record. A per-record query would be 200+.
        Assert.isTrue(queriesUsed <= 5, 'Expected a handful of queries for 200 records, used ' + queriesUsed);
        Assert.isTrue(dmlUsed <= 5, 'Expected a handful of DML statements for 200 records, used ' + dmlUsed);
    }

    @IsTest
    static void closedWon_alreadyWonOpportunityResaved_createsNothing() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqCommitService.commitConfiguration(opp.Id, CpqTestData.request(CpqTestData.BRAND, 595.00));
        close(opp);
        Integer entitlementsAfterClose = [SELECT COUNT() FROM Customer_Entitlement__c];

        Test.startTest();
        // The trigger fires on the transition into Closed Won, not on every save of a won deal.
        opp.Description = 'Someone edited the description six months later';
        update opp;
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Subscription__c], 'No duplicate subscription.');
        Assert.areEqual(entitlementsAfterClose, [SELECT COUNT() FROM Customer_Entitlement__c], 'No duplicates.');
    }

    @IsTest
    static void closedWon_lostThenWon_generatesOnceOnTheWinningTransition() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqCommitService.commitConfiguration(opp.Id, CpqTestData.request(CpqTestData.LAUNCH, 295.00));

        Test.startTest();
        opp.StageName = 'Closed Lost';
        update opp;
        Assert.areEqual(0, [SELECT COUNT() FROM Subscription__c], 'A lost deal entitles nothing.');

        opp.StageName = 'Closed Won';
        update opp;
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Subscription__c]);
    }

    // =====================================================================
    // Durability (R-3, R-21)
    // =====================================================================

    @IsTest
    static void closedWon_catalogPriceChangedAfterCommit_entitlementUnaffected() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 1, 100.00);
        CpqCommitService.commitConfiguration(opp.Id, request);
        close(opp);

        Decimal quantityBefore = CpqTestData.entitlementsByFeature(opp.Id).get('FEAT_CONTACTS').Quantity__c;
        Assert.areEqual(1000, quantityBefore.intValue());

        Test.startTest();
        // RevOps reprices the catalog and shrinks the contact pack. What was already sold is not
        // renegotiated by a catalog edit.
        CPQ_Catalog_Item__c contacts = [SELECT Id FROM CPQ_Catalog_Item__c WHERE Code__c = :CpqTestData.CONTACTS];
        contacts.List_Price__c = 250;
        contacts.Price_Floor__c = 200;
        contacts.Feature_Quantity_Per_Unit__c = 250;
        update contacts;
        Test.stopTest();

        Assert.areEqual(
            1000,
            CpqTestData.entitlementsByFeature(opp.Id).get('FEAT_CONTACTS').Quantity__c.intValue(),
            'A catalog change must not retroactively alter an existing entitlement.'
        );
        Assert.areEqual(
            100.00,
            [SELECT UnitPrice FROM OpportunityLineItem WHERE OpportunityId = :opp.Id AND CPQ_Catalog_Item__c = :contacts.Id]
            .UnitPrice,
            'Nor the price that was actually sold.'
        );
    }

    @IsTest
    static void closedWon_regeneration_supersedesRatherThanOverwrites() {
        // A future entry point that bypasses the trigger's transition guard must still not
        // duplicate: the unique External Id on the subscription is the structural backstop.
        Opportunity opp = CpqTestData.newOpportunity();
        CpqCommitService.commitConfiguration(opp.Id, CpqTestData.request(CpqTestData.BRAND, 595.00));
        close(opp);

        Test.startTest();
        CpqEntitlementService.generate(new Set<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Subscription__c], 'Upsert on the external key, not a second row.');
        Assert.areEqual(
            3,
            [SELECT COUNT() FROM Customer_Entitlement__c WHERE Status__c = 'Superseded'],
            'History is superseded, not deleted.'
        );
        Assert.areEqual(3, [SELECT COUNT() FROM Customer_Entitlement__c WHERE Status__c = 'Active']);
    }

    @IsTest
    static void closedWon_opportunityWithNoCpqLines_isIgnored() {
        Opportunity opp = CpqTestData.newOpportunity();

        Test.startTest();
        close(opp);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Subscription__c], 'A deal this API never configured is not ours.');
    }
}
