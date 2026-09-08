/**
 * An in-memory snapshot of the sellable catalog, resolved for one effective date.
 *
 * Loaded once per request and passed to the validator and the commit service, so a configuration
 * is judged against a single consistent view of the catalog rather than re-querying per line.
 *
 * It deliberately holds inactive items too. If it held only the effective ones, an inactive code
 * would be indistinguishable from a typo, and the caller needs those to be different errors
 * (UNKNOWN_CATALOG_CODE vs INACTIVE_CATALOG_ITEM).
 */
public with sharing class CpqCatalog {
    public final Date effectiveDate;
    public final Datetime catalogVersion;

    private final Map<String, CPQ_Catalog_Item__c> itemsByCode;
    private final Map<Id, List<CPQ_Plan_Feature__c>> planFeaturesByPlanId;

    public CpqCatalog(
        Date effectiveDate,
        List<CPQ_Catalog_Item__c> items,
        List<CPQ_Plan_Feature__c> planFeatures,
        Datetime catalogVersion
    ) {
        this.effectiveDate = effectiveDate;
        this.catalogVersion = catalogVersion;
        this.itemsByCode = new Map<String, CPQ_Catalog_Item__c>();
        this.planFeaturesByPlanId = new Map<Id, List<CPQ_Plan_Feature__c>>();

        for (CPQ_Catalog_Item__c item : items) {
            itemsByCode.put(item.Code__c, item);
        }
        for (CPQ_Plan_Feature__c pf : planFeatures) {
            if (!planFeaturesByPlanId.containsKey(pf.Plan__c)) {
                planFeaturesByPlanId.put(pf.Plan__c, new List<CPQ_Plan_Feature__c>());
            }
            planFeaturesByPlanId.get(pf.Plan__c).add(pf);
        }
    }

    /** The item for a code, or null if no such code exists at all. */
    public CPQ_Catalog_Item__c item(String code) {
        return String.isBlank(code) ? null : itemsByCode.get(code);
    }

    public Boolean exists(String code) {
        return item(code) != null;
    }

    /**
     * Whether an item may be quoted on this catalog's effective date (R-2). A null boundary is an
     * open end of the window, so an item with no dates set is always effective while Active__c.
     */
    public Boolean isEffective(String code) {
        CPQ_Catalog_Item__c item = item(code);
        if (item == null || item.Active__c != true) {
            return false;
        }
        if (item.Effective_Start__c != null && item.Effective_Start__c > effectiveDate) {
            return false;
        }
        if (item.Effective_End__c != null && item.Effective_End__c < effectiveDate) {
            return false;
        }
        return true;
    }

    public List<CPQ_Plan_Feature__c> planFeatures(Id planId) {
        List<CPQ_Plan_Feature__c> found = planFeaturesByPlanId.get(planId);
        return found == null ? new List<CPQ_Plan_Feature__c>() : found;
    }

    /** Every item of a given type that is effective today, for building the catalog response. */
    public List<CPQ_Catalog_Item__c> effectiveItemsOfType(String itemType) {
        List<CPQ_Catalog_Item__c> result = new List<CPQ_Catalog_Item__c>();
        for (CPQ_Catalog_Item__c item : itemsByCode.values()) {
            if (item.Item_Type__c == itemType && isEffective(item.Code__c)) {
                result.add(item);
            }
        }
        return result;
    }
}
