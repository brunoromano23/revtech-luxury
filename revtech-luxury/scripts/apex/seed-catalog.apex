// Seeds the reference catalog from the brief: 3 plans, 3 setup fees, 3 add-ons, 4 features,
// and the Product2/PricebookEntry rows OpportunityLineItem requires.
//
//   sf apex run --file scripts/apex/seed-catalog.apex
//
// Idempotent: everything upserts on its code, so re-running is safe.
CpqCatalogSeed.run();

System.debug('Features:      ' + [SELECT COUNT() FROM CPQ_Feature__c]);
System.debug('Catalog items: ' + [SELECT COUNT() FROM CPQ_Catalog_Item__c]);
System.debug('Plan features: ' + [SELECT COUNT() FROM CPQ_Plan_Feature__c]);
for (CPQ_Catalog_Item__c item : [
    SELECT Code__c, Name, Item_Type__c, List_Price__c, Price_Floor__c, Charge_Type__c
    FROM CPQ_Catalog_Item__c
    ORDER BY Item_Type__c, List_Price__c
]) {
    System.debug(
        item.Item_Type__c.rightPad(11) + item.Code__c.rightPad(28) +
        ('list ' + item.List_Price__c).rightPad(14) + 'floor ' + item.Price_Floor__c
    );
}
