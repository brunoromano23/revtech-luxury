/**
 * Test fixtures. Builds against CpqCatalogSeed rather than a private copy of the catalog, so the
 * tests assert on the same reference data a reviewer sees in the org.
 */
@IsTest
public class CpqTestData {
    public static final String LAUNCH = 'PLAN_LAUNCH';
    public static final String BRAND = 'PLAN_BRAND';
    public static final String ALL_IN = 'PLAN_ALL_IN';
    public static final String CONTACTS = 'ADDON_CONTACTS_500';
    public static final String COMPETITOR = 'ADDON_COMPETITOR_ANALYSIS';
    public static final String DESIGN_REFRESH = 'ADDON_DESIGN_REFRESH';

    /** Call from @TestSetup. */
    public static void seed() {
        CpqCatalogSeed.run();
        insert new Account(Name = 'Sotheby\'s International Realty');
    }

    public static Account account() {
        return [SELECT Id FROM Account LIMIT 1];
    }

    public static Opportunity newOpportunity() {
        return newOpportunities(1)[0];
    }

    public static List<Opportunity> newOpportunities(Integer count) {
        Id accountId = account().Id;
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opps.add(
                new Opportunity(
                    Name = 'Deal ' + i,
                    AccountId = accountId,
                    StageName = 'Prospecting',
                    CloseDate = Date.today().addDays(30),
                    Pricebook2Id = Test.getStandardPricebookId()
                )
            );
        }
        insert opps;
        return opps;
    }

    // =====================================================================
    // Request builders
    // =====================================================================

    public static CpqDto.ConfigurationRequest request(String planCode, Decimal planPrice) {
        CpqDto.ConfigurationRequest r = new CpqDto.ConfigurationRequest();
        r.correlationId = 'test-' + planCode;
        r.actingRepEmail = UserInfo.getUserName();
        r.planCode = planCode;
        r.planPrice = planPrice;
        r.addOns = new List<CpqDto.AddOnLine>();
        r.contractEffectiveDate = Date.today();
        r.contractTermMonths = 12;
        r.idempotencyKey = 'key-' + planCode + '-' + Math.abs(Crypto.getRandomInteger());
        return r;
    }

    public static CpqDto.ConfigurationRequest withAddOn(
        CpqDto.ConfigurationRequest request,
        String code,
        Integer quantity,
        Decimal unitPrice
    ) {
        CpqDto.AddOnLine line = new CpqDto.AddOnLine();
        line.code = code;
        line.quantity = quantity;
        line.unitPrice = unitPrice;
        request.addOns.add(line);
        return request;
    }

    // =====================================================================
    // Catalog access
    // =====================================================================

    public static Map<String, CPQ_Catalog_Item__c> itemsByCode() {
        Map<String, CPQ_Catalog_Item__c> byCode = new Map<String, CPQ_Catalog_Item__c>();
        for (CPQ_Catalog_Item__c item : [
            SELECT Id, Code__c, Item_Type__c, Charge_Type__c, Product__c, List_Price__c, Price_Floor__c
            FROM CPQ_Catalog_Item__c
        ]) {
            byCode.put(item.Code__c, item);
        }
        return byCode;
    }

    public static Map<Id, Id> pricebookEntriesByProduct() {
        Map<Id, Id> byProduct = new Map<Id, Id>();
        for (PricebookEntry entry : [
            SELECT Id, Product2Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :Test.getStandardPricebookId()
        ]) {
            byProduct.put(entry.Product2Id, entry.Id);
        }
        return byProduct;
    }

    /**
     * Writes CPQ-stamped line items directly, bypassing the commit endpoint. The bulk trigger test
     * needs 200 configured Opportunities, and 200 round trips through commit would prove nothing
     * about the trigger while burning the whole test's limits.
     */
    public static void addCpqLines(List<Opportunity> opps, List<String> itemCodes, List<Integer> quantities) {
        Map<String, CPQ_Catalog_Item__c> items = itemsByCode();
        Map<Id, Id> entries = pricebookEntriesByProduct();

        List<OpportunityLineItem> lines = new List<OpportunityLineItem>();
        for (Opportunity opp : opps) {
            for (Integer i = 0; i < itemCodes.size(); i++) {
                CPQ_Catalog_Item__c item = items.get(itemCodes[i]);
                lines.add(
                    new OpportunityLineItem(
                        OpportunityId = opp.Id,
                        PricebookEntryId = entries.get(item.Product__c),
                        Quantity = quantities[i],
                        UnitPrice = item.List_Price__c,
                        CPQ_Catalog_Item__c = item.Id,
                        CPQ_Charge_Type__c = item.Charge_Type__c
                    )
                );
            }
        }
        insert lines;
    }

    public static void setContractTerms(List<Opportunity> opps, Date effectiveDate, Integer termMonths) {
        for (Opportunity opp : opps) {
            opp.Contract_Effective_Date__c = effectiveDate;
            opp.Contract_Term_Months__c = termMonths;
        }
        update opps;
    }

    public static Map<String, Customer_Entitlement__c> entitlementsByFeature(Id opportunityId) {
        Map<String, Customer_Entitlement__c> byFeature = new Map<String, Customer_Entitlement__c>();
        for (Customer_Entitlement__c entitlement : [
            SELECT Id, Feature_Code__c, Quantity__c, Metering_Type__c, Status__c, Active_From__c, Active_To__c
            FROM Customer_Entitlement__c
            WHERE Source_Opportunity__c = :opportunityId AND Status__c = 'Active'
        ]) {
            byFeature.put(entitlement.Feature_Code__c, entitlement);
        }
        return byFeature;
    }
}
