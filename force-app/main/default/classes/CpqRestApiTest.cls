/**
 * The three endpoints end to end: catalog shape, the 200/422 asymmetry, and the typed errors a
 * client that sends garbage should get back instead of an Apex stack trace.
 */
@IsTest
private class CpqRestApiTest {
    @TestSetup
    static void setup() {
        CpqTestData.seed();
    }

    private static void prepare(String method, String uri, Object body) {
        RestRequest request = new RestRequest();
        request.httpMethod = method;
        request.requestURI = uri;
        request.addHeader(CpqRestSupport.HEADER_CORRELATION, 'corr-12345');
        if (body != null) {
            request.requestBody = Blob.valueOf(body instanceof String ? (String) body : JSON.serialize(body));
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    private static String body() {
        return RestContext.response.responseBody.toString();
    }

    // =====================================================================
    // GET /catalog
    // =====================================================================

    @IsTest
    static void catalog_returnsActivePlansAndAddOnsWithCodes() {
        prepare('GET', '/services/apexrest/cpq/v1/catalog', null);

        Test.startTest();
        CpqCatalogResource.getCatalog();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        CpqDto.CatalogResponse response = (CpqDto.CatalogResponse) JSON.deserialize(
            body(),
            CpqDto.CatalogResponse.class
        );

        Assert.areEqual('corr-12345', response.correlationId, 'The caller\'s correlation ID must be echoed.');
        Assert.areEqual(3, response.plans.size());
        Assert.areEqual(3, response.addOns.size());
        Assert.isNotNull(response.catalogVersion, 'The platform caches on this.');
        Assert.areEqual(new List<Integer>{ 12, 24, 36 }, response.permittedContractTerms);

        Map<String, CpqDto.PlanDto> plans = new Map<String, CpqDto.PlanDto>();
        for (CpqDto.PlanDto plan : response.plans) {
            plans.put(plan.code, plan);
        }

        CpqDto.PlanDto brand = plans.get('PLAN_BRAND');
        Assert.areEqual(595.00, brand.listPrice);
        Assert.areEqual(450.00, brand.priceFloor);
        Assert.areEqual(1000.00, brand.setupFee.listPrice);
        Assert.areEqual(3, brand.includedFeatures.size(), 'Hosting, feeds and one contact pack.');

        Map<String, CpqDto.IncludedFeatureDto> included = new Map<String, CpqDto.IncludedFeatureDto>();
        for (CpqDto.IncludedFeatureDto f : brand.includedFeatures) {
            included.put(f.featureCode, f);
        }
        Assert.areEqual(500, included.get('FEAT_CONTACTS').quantity.intValue());
        Assert.areEqual(CpqConstants.METERING_METERED, included.get('FEAT_CONTACTS').meteringType);
        Assert.isNull(included.get('FEAT_WEBSITE_HOSTING').quantity, 'Binary features carry no quantity.');

        Assert.areEqual(4, plans.get('PLAN_ALL_IN').includedFeatures.size());

        Map<String, CpqDto.AddOnDto> addOns = new Map<String, CpqDto.AddOnDto>();
        for (CpqDto.AddOnDto addOn : response.addOns) {
            addOns.put(addOn.code, addOn);
        }
        Assert.areEqual('FEAT_CONTACTS', addOns.get('ADDON_CONTACTS_500').featureCode);
        Assert.areEqual(500, addOns.get('ADDON_CONTACTS_500').featureQuantityPerUnit.intValue());
        Assert.isNull(addOns.get('ADDON_DESIGN_REFRESH').featureCode, 'Design Refresh grants nothing.');
        Assert.areEqual(CpqConstants.CHARGE_ONE_TIME, addOns.get('ADDON_DESIGN_REFRESH').chargeType);
    }

    @IsTest
    static void catalog_effectiveDateExcludesExpiredItems() {
        CPQ_Catalog_Item__c competitor = [SELECT Id FROM CPQ_Catalog_Item__c WHERE Code__c = :CpqTestData.COMPETITOR];
        competitor.Effective_End__c = Date.today().addDays(-1);
        update competitor;

        prepare('GET', '/services/apexrest/cpq/v1/catalog', null);
        RestContext.request.params.put('effectiveDate', String.valueOf(Date.today()));

        Test.startTest();
        CpqCatalogResource.getCatalog();
        Test.stopTest();

        CpqDto.CatalogResponse response = (CpqDto.CatalogResponse) JSON.deserialize(
            body(),
            CpqDto.CatalogResponse.class
        );
        Assert.areEqual(2, response.addOns.size(), 'The withdrawn add-on must not be offered.');
        for (CpqDto.AddOnDto addOn : response.addOns) {
            Assert.areNotEqual(CpqTestData.COMPETITOR, addOn.code);
        }
    }

    @IsTest
    static void catalog_malformedEffectiveDate_returns400() {
        prepare('GET', '/services/apexrest/cpq/v1/catalog', null);
        RestContext.request.params.put('effectiveDate', 'last-tuesday');

        CpqCatalogResource.getCatalog();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.isTrue(body().contains('INVALID_EFFECTIVE_DATE'));
    }

    // =====================================================================
    // POST /validate — a refusal is still a successful call
    // =====================================================================

    @IsTest
    static void validate_subFloorConfiguration_is200WithValidFalse() {
        prepare(
            'POST',
            '/services/apexrest/cpq/v1/configurations/validate',
            CpqTestData.request(CpqTestData.BRAND, 425.00)
        );

        Test.startTest();
        CpqValidateResource.validate();
        Test.stopTest();

        // "Is this valid?" was answered successfully. The answer was no.
        Assert.areEqual(200, RestContext.response.statusCode, 'A refused validate is still a 200.');
        CpqDto.ValidationResponse response = (CpqDto.ValidationResponse) JSON.deserialize(
            body(),
            CpqDto.ValidationResponse.class
        );
        Assert.isFalse(response.valid);
        Assert.areEqual(CpqConstants.V_PLAN_BELOW_FLOOR, response.violations[0].code);
        Assert.areEqual(450.00, response.violations[0].permitted);
    }

    @IsTest
    static void validate_validConfiguration_returnsTotals() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 2, 100.00);
        prepare('POST', '/services/apexrest/cpq/v1/configurations/validate', request);

        CpqValidateResource.validate();

        Assert.areEqual(200, RestContext.response.statusCode);
        CpqDto.ValidationResponse response = (CpqDto.ValidationResponse) JSON.deserialize(
            body(),
            CpqDto.ValidationResponse.class
        );
        Assert.isTrue(response.valid);
        Assert.areEqual(795.00, response.totals.monthlyRecurring);
        Assert.areEqual(10540.00, response.totals.totalContractValue, '795 x 12 + 1000');
    }

    @IsTest
    static void validate_malformedJson_returns400NotAnApexError() {
        prepare('POST', '/services/apexrest/cpq/v1/configurations/validate', '{"planCode": ');

        CpqValidateResource.validate();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.isTrue(body().contains('MALFORMED_BODY'));
        Assert.isFalse(body().contains('Class.'), 'A stack trace must never reach the caller.');
    }

    @IsTest
    static void validate_emptyBody_returns400() {
        prepare('POST', '/services/apexrest/cpq/v1/configurations/validate', null);
        CpqValidateResource.validate();
        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.isTrue(body().contains('EMPTY_BODY'));
    }

    // =====================================================================
    // POST /commit — refusing to write is a 422
    // =====================================================================

    @IsTest
    static void commit_validConfiguration_returns200AndLineIds() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 500.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 1, 100.00);
        prepare('POST', '/services/apexrest/cpq/v1/opportunities/' + opp.Id + '/commit', request);

        Test.startTest();
        CpqCommitResource.commitConfiguration();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        CpqDto.CommitResponse response = (CpqDto.CommitResponse) JSON.deserialize(body(), CpqDto.CommitResponse.class);
        Assert.areEqual(opp.Id, response.opportunityId);
        Assert.areEqual(3, response.lineItemIds.size());
        Assert.isFalse(response.replayed);
        Assert.areEqual(600.00, response.totals.monthlyRecurring);
    }

    @IsTest
    static void commit_subFloorConfiguration_returns422WithViolations() {
        Opportunity opp = CpqTestData.newOpportunity();
        prepare(
            'POST',
            '/services/apexrest/cpq/v1/opportunities/' + opp.Id + '/commit',
            CpqTestData.request(CpqTestData.BRAND, 400.00)
        );

        Test.startTest();
        CpqCommitResource.commitConfiguration();
        Test.stopTest();

        // Commit asked us to write, and we declined. That is a failed action, so 422 — unlike
        // validate, where answering "no" is a successful answer.
        Assert.areEqual(422, RestContext.response.statusCode);
        Assert.isTrue(body().contains(CpqConstants.V_PLAN_BELOW_FLOOR));
        Assert.areEqual(0, [SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId = :opp.Id]);
    }

    @IsTest
    static void commit_malformedOpportunityId_returns400NotException() {
        prepare(
            'POST',
            '/services/apexrest/cpq/v1/opportunities/not-an-id/commit',
            CpqTestData.request(CpqTestData.BRAND, 595.00)
        );

        CpqCommitResource.commitConfiguration();

        Assert.areEqual(400, RestContext.response.statusCode, 'A bad Id is the caller\'s mistake, not a 500.');
        Assert.isTrue(body().contains('INVALID_OPPORTUNITY_ID'));
    }

    @IsTest
    static void commit_idOfTheWrongSObjectType_returns400() {
        // An Account Id is well-formed but is not an Opportunity.
        prepare(
            'POST',
            '/services/apexrest/cpq/v1/opportunities/' + CpqTestData.account().Id + '/commit',
            CpqTestData.request(CpqTestData.BRAND, 595.00)
        );

        CpqCommitResource.commitConfiguration();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.isTrue(body().contains('INVALID_OPPORTUNITY_ID'));
    }

    @IsTest
    static void commit_missingIdempotencyKey_returns400() {
        Opportunity opp = CpqTestData.newOpportunity();
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        request.idempotencyKey = null;
        prepare('POST', '/services/apexrest/cpq/v1/opportunities/' + opp.Id + '/commit', request);

        CpqCommitResource.commitConfiguration();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.isTrue(body().contains('IDEMPOTENCY_KEY_REQUIRED'));
    }

    @IsTest
    static void commit_closedOpportunity_returns409() {
        Opportunity opp = CpqTestData.newOpportunity();
        OpportunityCpqHandler.disabled = true;
        opp.StageName = 'Closed Won';
        update opp;
        OpportunityCpqHandler.disabled = false;

        prepare(
            'POST',
            '/services/apexrest/cpq/v1/opportunities/' + opp.Id + '/commit',
            CpqTestData.request(CpqTestData.BRAND, 595.00)
        );

        Test.startTest();
        CpqCommitResource.commitConfiguration();
        Test.stopTest();

        Assert.areEqual(409, RestContext.response.statusCode);
        Assert.isTrue(body().contains('OPPORTUNITY_CLOSED'));
    }

    @IsTest
    static void commit_unknownOpportunity_returns404() {
        prepare(
            'POST',
            '/services/apexrest/cpq/v1/opportunities/006000000000000AAA/commit',
            CpqTestData.request(CpqTestData.BRAND, 595.00)
        );

        CpqCommitResource.commitConfiguration();

        Assert.areEqual(404, RestContext.response.statusCode);
        Assert.isFalse(body().contains('403'), 'Not-found and not-permitted must be indistinguishable.');
    }

    // =====================================================================
    // Logging
    // =====================================================================

    @IsTest
    static void everyCall_isLoggedWithCorrelationIdAndOutcome() {
        prepare(
            'POST',
            '/services/apexrest/cpq/v1/configurations/validate',
            CpqTestData.request(CpqTestData.BRAND, 425.00)
        );

        Test.startTest();
        CpqValidateResource.validate();
        Test.stopTest();

        List<LogEntryEvent__e> logs = new List<LogEntryEvent__e>();
        for (LogEntryEvent__e event : CpqLogger.published) {
            if ('corr-12345'.equals(event.Correlation_Id__c)) {
                logs.add(event);
            }
        }
        Assert.areEqual(1, logs.size(), 'The caller\'s correlation ID is carried onto the log entry.');
        Assert.areEqual(LoggingLevel.WARN.name(), logs[0].LoggingLevel__c);
        Assert.areEqual(
            'POST /cpq/v1/configurations/validate',
            logs[0].EntryScenario__c,
            'Scenario groups the transaction by the endpoint that drove it.'
        );

        // Sub-floor attempts are commercially interesting data, not noise. The violation codes are
        // tags rather than a delimited string, so counting them is a report and not a text search.
        Assert.isTrue(
            logs[0].Tags__c != null && logs[0].Tags__c.contains(CpqConstants.V_PLAN_BELOW_FLOOR),
            'The violation code must be tagged, found: ' + logs[0].Tags__c
        );
    }
}
