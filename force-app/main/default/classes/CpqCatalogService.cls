/**
 * Reads the catalog and shapes it for the platform.
 *
 * Two SOQL queries regardless of how large the catalog gets, and both run WITH USER_MODE so the
 * caller's CRUD/FLS applies without any hand-rolled isAccessible() checks to drift (design doc 7.1).
 */
public with sharing class CpqCatalogService {
    /** Loads the whole catalog once and resolves it against an effective date. */
    public static CpqCatalog load(Date effectiveDate) {
        Date asOf = effectiveDate == null ? Date.today() : effectiveDate;

        List<CPQ_Catalog_Item__c> items = [
            SELECT
                Id,
                Name,
                Code__c,
                Item_Type__c,
                List_Price__c,
                Price_Floor__c,
                Charge_Type__c,
                Active__c,
                Effective_Start__c,
                Effective_End__c,
                Feature_Quantity_Per_Unit__c,
                Product__c,
                Feature__c,
                Feature__r.Code__c,
                Feature__r.Metering_Type__c,
                Setup_Fee_Item__c,
                Setup_Fee_Item__r.Code__c,
                Setup_Fee_Item__r.Name,
                Setup_Fee_Item__r.List_Price__c,
                Setup_Fee_Item__r.Price_Floor__c,
                Setup_Fee_Item__r.Product__c,
                Setup_Fee_Item__r.Charge_Type__c,
                SystemModstamp
            FROM CPQ_Catalog_Item__c
            WITH USER_MODE
            ORDER BY List_Price__c ASC
        ];

        List<CPQ_Plan_Feature__c> planFeatures = [
            SELECT Id, Plan__c, Feature__c, Feature__r.Code__c, Feature__r.Metering_Type__c, Quantity__c, SystemModstamp
            FROM CPQ_Plan_Feature__c
            WITH USER_MODE
        ];

        Datetime version = null;
        for (CPQ_Catalog_Item__c item : items) {
            if (version == null || item.SystemModstamp > version) {
                version = item.SystemModstamp;
            }
        }
        for (CPQ_Plan_Feature__c pf : planFeatures) {
            if (version == null || pf.SystemModstamp > version) {
                version = pf.SystemModstamp;
            }
        }

        return new CpqCatalog(asOf, items, planFeatures, version);
    }

    /**
     * The GET /catalog payload. Every item carries its code so the platform never has to store a
     * Salesforce Id, and the version lets it cache and cheaply detect staleness (design doc 6.2).
     */
    public static CpqDto.CatalogResponse describe(CpqCatalog catalog, String correlationId) {
        CpqDto.CatalogResponse response = new CpqDto.CatalogResponse();
        response.correlationId = correlationId;
        response.effectiveDate = catalog.effectiveDate;
        response.catalogVersion = catalog.catalogVersion == null
            ? null
            : catalog.catalogVersion.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        response.permittedContractTerms = new List<Integer>(CpqConstants.permittedContractTerms());
        response.permittedContractTerms.sort();
        response.plans = new List<CpqDto.PlanDto>();
        response.addOns = new List<CpqDto.AddOnDto>();

        for (CPQ_Catalog_Item__c plan : catalog.effectiveItemsOfType(CpqConstants.TYPE_PLAN)) {
            CpqDto.PlanDto dto = new CpqDto.PlanDto();
            dto.code = plan.Code__c;
            dto.name = plan.Name;
            dto.listPrice = plan.List_Price__c;
            dto.priceFloor = plan.Price_Floor__c;
            dto.chargeType = plan.Charge_Type__c;

            if (plan.Setup_Fee_Item__c != null) {
                CpqDto.SetupFeeDto fee = new CpqDto.SetupFeeDto();
                fee.code = plan.Setup_Fee_Item__r.Code__c;
                fee.name = plan.Setup_Fee_Item__r.Name;
                fee.listPrice = plan.Setup_Fee_Item__r.List_Price__c;
                fee.priceFloor = plan.Setup_Fee_Item__r.Price_Floor__c;
                dto.setupFee = fee;
            }

            dto.includedFeatures = new List<CpqDto.IncludedFeatureDto>();
            for (CPQ_Plan_Feature__c pf : catalog.planFeatures(plan.Id)) {
                CpqDto.IncludedFeatureDto inc = new CpqDto.IncludedFeatureDto();
                inc.featureCode = pf.Feature__r.Code__c;
                inc.meteringType = pf.Feature__r.Metering_Type__c;
                inc.quantity = pf.Quantity__c;
                dto.includedFeatures.add(inc);
            }
            response.plans.add(dto);
        }

        for (CPQ_Catalog_Item__c addOn : catalog.effectiveItemsOfType(CpqConstants.TYPE_ADDON)) {
            CpqDto.AddOnDto dto = new CpqDto.AddOnDto();
            dto.code = addOn.Code__c;
            dto.name = addOn.Name;
            dto.listPrice = addOn.List_Price__c;
            dto.priceFloor = addOn.Price_Floor__c;
            dto.chargeType = addOn.Charge_Type__c;
            dto.featureQuantityPerUnit = addOn.Feature_Quantity_Per_Unit__c;
            // Null for a sellable-but-non-entitling add-on such as Design Refresh. The platform
            // can render that distinction; it does not have to know the product by name.
            dto.featureCode = addOn.Feature__c == null ? null : addOn.Feature__r.Code__c;
            dto.meteringType = addOn.Feature__c == null ? null : addOn.Feature__r.Metering_Type__c;
            response.addOns.add(dto);
        }

        return response;
    }
}
