/**
 * The wire contract with the React/NestJS platform.
 *
 * These shapes are the API. They are deliberately plain data with no behaviour, so the JSON the
 * platform sees is obvious from reading this one file rather than inferred from serialisation of
 * SObjects — which would leak field API names and couple the contract to the data model.
 */
public with sharing class CpqDto {
    // =====================================================================
    // Requests
    // =====================================================================

    /** A proposed deal. The same shape is posted to /validate and /commit. */
    public class ConfigurationRequest {
        public String correlationId;
        public String actingRepEmail;
        public String planCode;
        public Decimal planPrice;
        public Decimal setupFee;
        public List<AddOnLine> addOns;
        public Date contractEffectiveDate;
        public Integer contractTermMonths;
        /** Commit only. Ignored by /validate, which has no side effects to make idempotent. */
        public String idempotencyKey;
    }

    public class AddOnLine {
        public String code;
        public Integer quantity;
        public Decimal unitPrice;
    }

    // =====================================================================
    // Catalog response
    // =====================================================================

    public class CatalogResponse {
        public String correlationId;
        public Date effectiveDate;
        /** Max SystemModstamp across catalog objects, so the platform can cache and detect staleness. */
        public String catalogVersion;
        public List<Integer> permittedContractTerms;
        public List<PlanDto> plans;
        public List<AddOnDto> addOns;
    }

    public class PlanDto {
        public String code;
        public String name;
        public Decimal listPrice;
        public Decimal priceFloor;
        public String chargeType;
        public SetupFeeDto setupFee;
        public List<IncludedFeatureDto> includedFeatures;
    }

    public class SetupFeeDto {
        public String code;
        public String name;
        public Decimal listPrice;
        public Decimal priceFloor;
    }

    public class IncludedFeatureDto {
        public String featureCode;
        public String meteringType;
        /** Null for binary features: "included" is the whole statement, there is no quantity. */
        public Decimal quantity;
    }

    public class AddOnDto {
        public String code;
        public String name;
        public Decimal listPrice;
        public Decimal priceFloor;
        public String chargeType;
        /** Null where the add-on grants no capability, e.g. Design Refresh. */
        public String featureCode;
        public String meteringType;
        public Decimal featureQuantityPerUnit;
    }

    // =====================================================================
    // Validation response
    // =====================================================================

    public class ValidationResponse {
        public String correlationId;
        public Boolean valid;
        public List<Violation> violations;
        /** Populated only when valid, so a rejected configuration never shows a price it cannot have. */
        public Totals totals;

        public ValidationResponse() {
            this.violations = new List<Violation>();
        }
    }

    public class Violation {
        public String code;
        /** The catalog code of the offending line, or null for configuration-level violations. */
        public String line;
        public Decimal submitted;
        public Decimal permitted;
        public String message;

        public Violation(String code, String line, Decimal submitted, Decimal permitted, String message) {
            this.code = code;
            this.line = line;
            this.submitted = submitted;
            this.permitted = permitted;
            this.message = message;
        }
    }

    public class Totals {
        public Decimal monthlyRecurring;
        public Decimal oneTime;
        /** What the customer pays on day one: the first month plus every one-time charge. */
        public Decimal firstInvoice;
        public Decimal totalContractValue;
    }

    // =====================================================================
    // Commit response
    // =====================================================================

    public class CommitResponse {
        public String correlationId;
        public String opportunityId;
        public String commitId;
        public List<String> lineItemIds;
        public Totals totals;
        public Date contractEffectiveDate;
        public Integer contractTermMonths;
        /** True when this request replayed an earlier commit with the same idempotency key. */
        public Boolean replayed;
    }

    // =====================================================================
    // Error envelope
    // =====================================================================

    /** Every non-2xx response the caller can act on. Never a raw Apex exception. */
    public class ErrorResponse {
        public String correlationId;
        public String code;
        public String message;
        /** Present on 422 so a refused commit tells the caller exactly what to fix. */
        public List<Violation> violations;

        public ErrorResponse(String correlationId, String code, String message) {
            this.correlationId = correlationId;
            this.code = code;
            this.message = message;
        }
    }
}
