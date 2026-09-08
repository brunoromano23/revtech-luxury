/**
 * Shared vocabulary for the CPQ surface.
 *
 * The violation codes are a published contract: the React/NestJS platform branches on them and
 * localises its own messages, so they are additive across versions. Removing or repurposing one
 * is a breaking change that earns a /v2 (solution design 6.3).
 */
public with sharing class CpqConstants {
    // --- Catalog item types ------------------------------------------------
    public static final String TYPE_PLAN = 'Plan';
    public static final String TYPE_ADDON = 'Add-On';
    public static final String TYPE_SETUP_FEE = 'Setup Fee';

    // --- Charge types ------------------------------------------------------
    public static final String CHARGE_RECURRING = 'Recurring Monthly';
    public static final String CHARGE_ONE_TIME = 'One-Time';

    // --- Metering ----------------------------------------------------------
    public static final String METERING_BINARY = 'Binary';
    public static final String METERING_METERED = 'Metered';

    // --- Violation codes (closed set) --------------------------------------
    public static final String V_PLAN_MISSING = 'PLAN_MISSING';
    public static final String V_PLAN_MULTIPLE = 'PLAN_MULTIPLE';
    public static final String V_PLAN_BELOW_FLOOR = 'PLAN_BELOW_FLOOR';
    public static final String V_ADDON_BELOW_FLOOR = 'ADDON_BELOW_FLOOR';
    public static final String V_ADDON_DUPLICATE = 'ADDON_DUPLICATE';
    public static final String V_ADDON_QUANTITY_INVALID = 'ADDON_QUANTITY_INVALID';
    public static final String V_SETUP_FEE_ABOVE_CATALOG = 'SETUP_FEE_ABOVE_CATALOG';
    public static final String V_UNKNOWN_CATALOG_CODE = 'UNKNOWN_CATALOG_CODE';
    public static final String V_INACTIVE_CATALOG_ITEM = 'INACTIVE_CATALOG_ITEM';
    public static final String V_INVALID_CONTRACT_TERM = 'INVALID_CONTRACT_TERM';
    public static final String V_EFFECTIVE_DATE_MISSING = 'EFFECTIVE_DATE_MISSING';
    public static final String V_NEGATIVE_PRICE = 'NEGATIVE_PRICE';
    public static final String V_PRICE_PRECISION_INVALID = 'PRICE_PRECISION_INVALID';

    // --- Log outcomes ------------------------------------------------------
    public static final String OUTCOME_SUCCESS = 'Success';
    public static final String OUTCOME_VALIDATION_FAILED = 'Validation Failed';
    public static final String OUTCOME_REJECTED = 'Rejected';
    public static final String OUTCOME_ERROR = 'Error';

    /**
     * Upper bound on add-on lines in one configuration. Bounding input before anything is queried
     * stops a hostile payload burning governor limits on its way to being rejected (design doc 7.1).
     */
    public static final Integer MAX_ADDON_LINES = 50;

    /** Permitted contract terms, from CPQ_Setting__mdt so Sales can change them without a deploy. */
    public static Set<Integer> permittedContractTerms() {
        if (termsOverride != null) {
            return termsOverride;
        }
        Set<Integer> terms = new Set<Integer>();
        List<CPQ_Setting__mdt> settings = CPQ_Setting__mdt.getAll().values();
        for (CPQ_Setting__mdt s : settings) {
            if (String.isBlank(s.Permitted_Contract_Terms__c)) {
                continue;
            }
            for (String part : s.Permitted_Contract_Terms__c.split(';')) {
                if (String.isNotBlank(part) && part.trim().isNumeric()) {
                    terms.add(Integer.valueOf(part.trim()));
                }
            }
        }
        // A org missing its configuration record should fail closed on the documented default
        // rather than accept any term a caller sends.
        if (terms.isEmpty()) {
            terms.addAll(new Set<Integer>{ 12, 24, 36 });
        }
        return terms;
    }

    @TestVisible
    private static Set<Integer> termsOverride;
}
