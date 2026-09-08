/**
 * The price-floor rules. Acceptance criteria live here as test methods rather than in a document,
 * so traceability is executable (solution design 10).
 */
@IsTest
private class CpqValidatorTest {
    @TestSetup
    static void setup() {
        CpqTestData.seed();
    }

    private static CpqValidator.Resolved validate(CpqDto.ConfigurationRequest request) {
        return CpqValidator.validate(request, CpqCatalogService.load(request.contractEffectiveDate));
    }

    private static Set<String> codes(CpqValidator.Resolved resolved) {
        Set<String> found = new Set<String>();
        for (CpqDto.Violation v : resolved.response.violations) {
            found.add(v.code);
        }
        return found;
    }

    // =====================================================================
    // The floor itself (R-7)
    // =====================================================================

    @IsTest
    static void validate_planPriceExactlyAtFloor_passes() {
        // The floor is inclusive. This is the boundary the whole exercise turns on, so it is
        // asserted directly rather than inferred from a comfortably-above-floor price.
        CpqValidator.Resolved resolved = validate(CpqTestData.request(CpqTestData.BRAND, 450.00));

        Assert.isTrue(resolved.isValid(), 'Brand at exactly the $450 floor must pass: ' + resolved.response.violations);
        Assert.areEqual(0, resolved.response.violations.size());
    }

    @IsTest
    static void validate_planPriceOneCentBelowFloor_fails() {
        CpqValidator.Resolved resolved = validate(CpqTestData.request(CpqTestData.BRAND, 449.99));

        Assert.isFalse(resolved.isValid(), 'One cent below floor must fail.');
        Assert.areEqual(1, resolved.response.violations.size());

        CpqDto.Violation violation = resolved.response.violations[0];
        Assert.areEqual(CpqConstants.V_PLAN_BELOW_FLOOR, violation.code);
        Assert.areEqual('PLAN_BRAND', violation.line);
        Assert.areEqual(449.99, violation.submitted);
        Assert.areEqual(450.00, violation.permitted, 'The response must tell the client what the floor is.');
        Assert.isNull(resolved.response.totals, 'A rejected configuration must not quote totals.');
    }

    @IsTest
    static void validate_allThreePlansEnforceTheirOwnFloor() {
        Assert.isFalse(validate(CpqTestData.request(CpqTestData.LAUNCH, 249.99)).isValid());
        Assert.isTrue(validate(CpqTestData.request(CpqTestData.LAUNCH, 250.00)).isValid());
        Assert.isFalse(validate(CpqTestData.request(CpqTestData.ALL_IN, 1999.99)).isValid());
        Assert.isTrue(validate(CpqTestData.request(CpqTestData.ALL_IN, 2000.00)).isValid());
    }

    // =====================================================================
    // Every violation in one response (R-11)
    // =====================================================================

    @IsTest
    static void validate_subFloorPlanAndSubFloorAddOn_returnsBothViolations() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 425.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 1, 70.00);

        CpqValidator.Resolved resolved = validate(request);

        Assert.isFalse(resolved.isValid());
        // A rep fixing two lines should make one round trip, not two.
        Assert.areEqual(2, resolved.response.violations.size(), 'Both violations must arrive together.');
        Assert.isTrue(codes(resolved).contains(CpqConstants.V_PLAN_BELOW_FLOOR));
        Assert.isTrue(codes(resolved).contains(CpqConstants.V_ADDON_BELOW_FLOOR));
    }

    // =====================================================================
    // Setup fee (R-9)
    // =====================================================================

    @IsTest
    static void validate_setupFeeAboveCatalogAmount_fails() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        request.setupFee = 1500.00;

        CpqValidator.Resolved resolved = validate(request);

        Assert.isFalse(resolved.isValid());
        Assert.areEqual(CpqConstants.V_SETUP_FEE_ABOVE_CATALOG, resolved.response.violations[0].code);
        Assert.areEqual(1000.00, resolved.response.violations[0].permitted);
    }

    @IsTest
    static void validate_setupFeeWaivedToZero_passes() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        request.setupFee = 0;

        CpqValidator.Resolved resolved = validate(request);

        Assert.isTrue(resolved.isValid(), 'A waived setup fee is legal: ' + resolved.response.violations);
        Assert.areEqual(0, resolved.response.totals.oneTime, 'A waived fee must not still be billed.');
    }

    @IsTest
    static void validate_setupFeeOmitted_defaultsToCatalogAmountRatherThanZero() {
        // A client that forgets the field must not accidentally give the setup fee away.
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        request.setupFee = null;

        CpqValidator.Resolved resolved = validate(request);

        Assert.isTrue(resolved.isValid());
        Assert.areEqual(1000.00, resolved.response.totals.oneTime);
    }

    // =====================================================================
    // Configuration shape (R-4, R-5)
    // =====================================================================

    @IsTest
    static void validate_duplicateAddOnLine_fails() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 1, 100.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 1, 100.00);

        CpqValidator.Resolved resolved = validate(request);

        Assert.isFalse(resolved.isValid(), 'Stacking is expressed as quantity, not repeated lines.');
        Assert.isTrue(codes(resolved).contains(CpqConstants.V_ADDON_DUPLICATE));
    }

    @IsTest
    static void validate_zeroPlansAndTwoPlans_fail() {
        CpqDto.ConfigurationRequest noPlan = CpqTestData.request(null, 595.00);
        CpqValidator.Resolved zero = validate(noPlan);
        Assert.isFalse(zero.isValid());
        Assert.isTrue(codes(zero).contains(CpqConstants.V_PLAN_MISSING));

        // A second plan smuggled in as an add-on line is still a second plan.
        CpqDto.ConfigurationRequest twoPlans = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqTestData.withAddOn(twoPlans, CpqTestData.LAUNCH, 1, 295.00);
        CpqValidator.Resolved two = validate(twoPlans);
        Assert.isFalse(two.isValid());
        Assert.isTrue(codes(two).contains(CpqConstants.V_PLAN_MULTIPLE));
    }

    @IsTest
    static void validate_addOnQuantityZeroOrNegative_fails() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 0, 100.00);

        Assert.isTrue(codes(validate(request)).contains(CpqConstants.V_ADDON_QUANTITY_INVALID));
    }

    // =====================================================================
    // Catalog resolution (R-2)
    // =====================================================================

    @IsTest
    static void validate_unknownAndInactiveCodes_returnDistinctViolationCodes() {
        // A typo and a withdrawn product are different problems and the client renders them
        // differently, so the catalog snapshot keeps inactive items rather than hiding them.
        CPQ_Catalog_Item__c competitor = [SELECT Id FROM CPQ_Catalog_Item__c WHERE Code__c = :CpqTestData.COMPETITOR];
        competitor.Active__c = false;
        update competitor;

        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqTestData.withAddOn(request, 'ADDON_DOES_NOT_EXIST', 1, 10.00);
        CpqTestData.withAddOn(request, CpqTestData.COMPETITOR, 1, 150.00);

        CpqValidator.Resolved resolved = validate(request);

        Assert.isFalse(resolved.isValid());
        Assert.isTrue(codes(resolved).contains(CpqConstants.V_UNKNOWN_CATALOG_CODE), 'Typo must be UNKNOWN.');
        Assert.isTrue(codes(resolved).contains(CpqConstants.V_INACTIVE_CATALOG_ITEM), 'Withdrawn must be INACTIVE.');
    }

    @IsTest
    static void validate_itemOutsideItsEffectiveWindow_isInactive() {
        CPQ_Catalog_Item__c contacts = [SELECT Id FROM CPQ_Catalog_Item__c WHERE Code__c = :CpqTestData.CONTACTS];
        contacts.Effective_Start__c = Date.today().addDays(30);
        update contacts;

        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 1, 100.00);

        Assert.isTrue(codes(validate(request)).contains(CpqConstants.V_INACTIVE_CATALOG_ITEM));

        // ...and is quotable again once the configuration's effective date reaches the window.
        request.contractEffectiveDate = Date.today().addDays(45);
        Assert.isTrue(validate(request).isValid());
    }

    // =====================================================================
    // Contract terms (R-12) and price shape (R-10)
    // =====================================================================

    @IsTest
    static void validate_unpermittedTermAndMissingEffectiveDate_fail() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 595.00);
        request.contractTermMonths = 18;
        request.contractEffectiveDate = null;

        Set<String> found = codes(validate(request));
        Assert.isTrue(found.contains(CpqConstants.V_INVALID_CONTRACT_TERM));
        Assert.isTrue(found.contains(CpqConstants.V_EFFECTIVE_DATE_MISSING));
    }

    @IsTest
    static void validate_negativeAndOverPrecisePrices_fail() {
        Assert.isTrue(
            codes(validate(CpqTestData.request(CpqTestData.BRAND, -100.00))).contains(CpqConstants.V_NEGATIVE_PRICE)
        );
        Assert.isTrue(
            codes(validate(CpqTestData.request(CpqTestData.BRAND, 595.001)))
                .contains(CpqConstants.V_PRICE_PRECISION_INVALID)
        );
    }

    // =====================================================================
    // Side effects and totals
    // =====================================================================

    @IsTest
    static void validate_performsNoDml() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 500.00);
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 2, 100.00);

        Integer dmlBefore = Limits.getDmlStatements();
        Test.startTest();
        validate(request);
        Test.stopTest();

        // /validate is called on every keystroke while a rep drags a slider. Anything it wrote
        // would be written hundreds of times per deal.
        Assert.areEqual(dmlBefore, Limits.getDmlStatements(), 'Validation must have no side effects.');
    }

    @IsTest
    static void validate_totals_separateRecurringFromOneTimeAcrossTheTerm() {
        CpqDto.ConfigurationRequest request = CpqTestData.request(CpqTestData.BRAND, 500.00);
        request.contractTermMonths = 24;
        CpqTestData.withAddOn(request, CpqTestData.CONTACTS, 2, 100.00); // 200/mo recurring
        CpqTestData.withAddOn(request, CpqTestData.DESIGN_REFRESH, 1, 750.00); // 750 one-time

        CpqDto.Totals totals = validate(request).response.totals;

        Assert.areEqual(700.00, totals.monthlyRecurring, '500 plan + 200 contacts');
        Assert.areEqual(1750.00, totals.oneTime, '1000 setup + 750 design refresh');
        Assert.areEqual(2450.00, totals.firstInvoice, 'First month plus every one-time charge');
        Assert.areEqual(18550.00, totals.totalContractValue, '700 x 24 + 1750');
    }
}
