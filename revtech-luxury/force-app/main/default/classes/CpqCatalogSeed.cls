/**
 * The reference catalog from the brief, defined once.
 *
 * Both the test suite and scripts/apex/seed-catalog.apex call this, so the data the tests assert
 * against is the same data a reviewer sees in the org — there is no second, drifting copy.
 *
 * Idempotent: everything upserts on its external Id code, so it can be re-run safely.
 *
 * Add-on prices and floors are the assumed values (A-1) pending RevOps confirmation (Q-2). They are
 * data, so changing them is an org edit, not a deployment.
 */
public with sharing class CpqCatalogSeed {
    public static void run() {
        Map<String, Id> features = seedFeatures();
        Map<String, Id> products = seedProducts();
        Map<String, CPQ_Catalog_Item__c> items = seedItems(features, products);
        seedPlanFeatures(features, items);
    }

    // ---------------------------------------------------------------- features
    private static Map<String, Id> seedFeatures() {
        List<CPQ_Feature__c> features = new List<CPQ_Feature__c>{
            feature('FEAT_WEBSITE_HOSTING', 'Website Hosting', CpqConstants.METERING_BINARY),
            feature('FEAT_LISTING_FEEDS', 'Listing Feeds', CpqConstants.METERING_BINARY),
            feature('FEAT_COMPETITOR_ANALYSIS', 'Competitor Analysis', CpqConstants.METERING_BINARY),
            // The only metered feature in the catalog, and the reason entitlements aggregate at all.
            feature('FEAT_CONTACTS', 'Contacts', CpqConstants.METERING_METERED)
        };
        upsert features Code__c;

        Map<String, Id> byCode = new Map<String, Id>();
        for (CPQ_Feature__c f : features) {
            byCode.put(f.Code__c, f.Id);
        }
        return byCode;
    }

    private static CPQ_Feature__c feature(String code, String name, String metering) {
        return new CPQ_Feature__c(Code__c = code, Name = name, Metering_Type__c = metering, Active__c = true);
    }

    // ---------------------------------------------------------------- products
    /**
     * A Product2 and a standard PricebookEntry per sellable item, because OpportunityLineItem
     * cannot exist without one (solution design 4.5).
     */
    private static Map<String, Id> seedProducts() {
        Map<String, String> names = new Map<String, String>{
            'PLAN_LAUNCH' => 'Launch',
            'PLAN_BRAND' => 'Brand',
            'PLAN_ALL_IN' => 'All In',
            'SETUP_LAUNCH' => 'Launch Setup Fee',
            'SETUP_BRAND' => 'Brand Setup Fee',
            'SETUP_ALL_IN' => 'All In Setup Fee',
            'ADDON_DESIGN_REFRESH' => 'Design Refresh',
            'ADDON_COMPETITOR_ANALYSIS' => 'Competitor Analysis',
            'ADDON_CONTACTS_500' => 'Contacts (500)'
        };

        // ProductCode is not an External Id, so there is no upsert key here. Match on what is
        // already there and insert only the gap, which keeps the seed re-runnable.
        Map<String, Id> byCode = new Map<String, Id>();
        for (Product2 existing : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN :names.keySet()]) {
            byCode.put(existing.ProductCode, existing.Id);
        }

        List<Product2> missing = new List<Product2>();
        for (String code : names.keySet()) {
            if (!byCode.containsKey(code)) {
                missing.add(new Product2(Name = names.get(code), ProductCode = code, IsActive = true));
            }
        }
        if (!missing.isEmpty()) {
            insert missing;
            for (Product2 p : missing) {
                byCode.put(p.ProductCode, p.Id);
            }
        }

        Id pricebookId = standardPricebookId();
        Set<Id> alreadyPriced = new Set<Id>();
        for (PricebookEntry existing : [
            SELECT Product2Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId AND Product2Id IN :byCode.values()
        ]) {
            alreadyPriced.add(existing.Product2Id);
        }

        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (String code : byCode.keySet()) {
            if (alreadyPriced.contains(byCode.get(code))) {
                continue;
            }
            entries.add(
                new PricebookEntry(
                    Pricebook2Id = pricebookId,
                    Product2Id = byCode.get(code),
                    // The catalog is the source of truth for price; this only has to exist and be
                    // active. The negotiated price is written onto the line item at commit.
                    UnitPrice = listPrice(code),
                    IsActive = true,
                    UseStandardPrice = false
                )
            );
        }
        if (!entries.isEmpty()) {
            insert entries;
        }
        return byCode;
    }

    // ------------------------------------------------------------- catalog items
    private static Map<String, CPQ_Catalog_Item__c> seedItems(Map<String, Id> features, Map<String, Id> products) {
        // Setup fees and add-ons first: plans point at their setup-fee item, so it must exist.
        List<CPQ_Catalog_Item__c> first = new List<CPQ_Catalog_Item__c>{
            item('SETUP_LAUNCH', 'Launch Setup Fee', CpqConstants.TYPE_SETUP_FEE, 500, 0, CpqConstants.CHARGE_ONE_TIME, products),
            item('SETUP_BRAND', 'Brand Setup Fee', CpqConstants.TYPE_SETUP_FEE, 1000, 0, CpqConstants.CHARGE_ONE_TIME, products),
            item('SETUP_ALL_IN', 'All In Setup Fee', CpqConstants.TYPE_SETUP_FEE, 2500, 0, CpqConstants.CHARGE_ONE_TIME, products),
            // Design Refresh has no Feature__c. That null is the entire mechanism by which it
            // reaches billing and never reaches feature gating (R-19).
            item('ADDON_DESIGN_REFRESH', 'Design Refresh', CpqConstants.TYPE_ADDON, 750, 600, CpqConstants.CHARGE_ONE_TIME, products),
            addOn('ADDON_COMPETITOR_ANALYSIS', 'Competitor Analysis', 150, 120, features.get('FEAT_COMPETITOR_ANALYSIS'), 1, products),
            addOn('ADDON_CONTACTS_500', 'Contacts (500)', 100, 80, features.get('FEAT_CONTACTS'), 500, products)
        };
        upsert first Code__c;

        Map<String, CPQ_Catalog_Item__c> byCode = new Map<String, CPQ_Catalog_Item__c>();
        for (CPQ_Catalog_Item__c i : first) {
            byCode.put(i.Code__c, i);
        }

        List<CPQ_Catalog_Item__c> plans = new List<CPQ_Catalog_Item__c>{
            plan('PLAN_LAUNCH', 'Launch', 295, 250, byCode.get('SETUP_LAUNCH').Id, products),
            plan('PLAN_BRAND', 'Brand', 595, 450, byCode.get('SETUP_BRAND').Id, products),
            plan('PLAN_ALL_IN', 'All In', 2495, 2000, byCode.get('SETUP_ALL_IN').Id, products)
        };
        upsert plans Code__c;
        for (CPQ_Catalog_Item__c p : plans) {
            byCode.put(p.Code__c, p);
        }
        return byCode;
    }

    private static CPQ_Catalog_Item__c item(
        String code,
        String name,
        String type,
        Decimal listAmount,
        Decimal floor,
        String chargeType,
        Map<String, Id> products
    ) {
        return new CPQ_Catalog_Item__c(
            Code__c = code,
            Name = name,
            Item_Type__c = type,
            List_Price__c = listAmount,
            Price_Floor__c = floor,
            Charge_Type__c = chargeType,
            Product__c = products.get(code),
            Active__c = true
        );
    }

    private static CPQ_Catalog_Item__c addOn(
        String code,
        String name,
        Decimal listAmount,
        Decimal floor,
        Id featureId,
        Decimal perUnit,
        Map<String, Id> products
    ) {
        CPQ_Catalog_Item__c i = item(code, name, CpqConstants.TYPE_ADDON, listAmount, floor, CpqConstants.CHARGE_RECURRING, products);
        i.Feature__c = featureId;
        i.Feature_Quantity_Per_Unit__c = perUnit;
        return i;
    }

    private static CPQ_Catalog_Item__c plan(
        String code,
        String name,
        Decimal listAmount,
        Decimal floor,
        Id setupFeeItemId,
        Map<String, Id> products
    ) {
        CPQ_Catalog_Item__c i = item(code, name, CpqConstants.TYPE_PLAN, listAmount, floor, CpqConstants.CHARGE_RECURRING, products);
        i.Setup_Fee_Item__c = setupFeeItemId;
        return i;
    }

    // ------------------------------------------------------------ plan features
    private static void seedPlanFeatures(Map<String, Id> features, Map<String, CPQ_Catalog_Item__c> items) {
        Set<Id> planIds = new Set<Id>{
            items.get('PLAN_LAUNCH').Id,
            items.get('PLAN_BRAND').Id,
            items.get('PLAN_ALL_IN').Id
        };
        // No external Id to upsert on, so the junction is rebuilt rather than merged.
        delete [SELECT Id FROM CPQ_Plan_Feature__c WHERE Plan__c IN :planIds];

        Id hosting = features.get('FEAT_WEBSITE_HOSTING');
        Id feeds = features.get('FEAT_LISTING_FEEDS');
        Id competitor = features.get('FEAT_COMPETITOR_ANALYSIS');
        Id contacts = features.get('FEAT_CONTACTS');

        Id launch = items.get('PLAN_LAUNCH').Id;
        Id brand = items.get('PLAN_BRAND').Id;
        Id allIn = items.get('PLAN_ALL_IN').Id;

        insert new List<CPQ_Plan_Feature__c>{
            inclusion(launch, hosting, null),
            inclusion(launch, feeds, null),
            inclusion(brand, hosting, null),
            inclusion(brand, feeds, null),
            // Contact pack x1.
            inclusion(brand, contacts, 500),
            inclusion(allIn, hosting, null),
            inclusion(allIn, feeds, null),
            inclusion(allIn, competitor, null),
            // Contact pack x2.
            inclusion(allIn, contacts, 1000)
        };
    }

    private static CPQ_Plan_Feature__c inclusion(Id planId, Id featureId, Decimal quantity) {
        return new CPQ_Plan_Feature__c(Plan__c = planId, Feature__c = featureId, Quantity__c = quantity);
    }

    // ---------------------------------------------------------------- helpers
    private static Decimal listPrice(String code) {
        Map<String, Decimal> prices = new Map<String, Decimal>{
            'PLAN_LAUNCH' => 295,
            'PLAN_BRAND' => 595,
            'PLAN_ALL_IN' => 2495,
            'SETUP_LAUNCH' => 500,
            'SETUP_BRAND' => 1000,
            'SETUP_ALL_IN' => 2500,
            'ADDON_DESIGN_REFRESH' => 750,
            'ADDON_COMPETITOR_ANALYSIS' => 150,
            'ADDON_CONTACTS_500' => 100
        };
        return prices.get(code);
    }

    private static Id standardPricebookId() {
        if (Test.isRunningTest()) {
            return Test.getStandardPricebookId();
        }
        return [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1].Id;
    }
}
