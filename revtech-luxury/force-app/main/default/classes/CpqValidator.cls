/**
 * Server-side enforcement of the commercial rules (solution design 3).
 *
 * Pure: no SOQL, no DML, no side effects. It takes a request and a catalog snapshot and returns a
 * verdict, which is what lets /validate be called on every keystroke and lets /commit re-run the
 * identical check without trusting anything the client did earlier (R-13).
 *
 * Every violation is collected rather than thrown on first failure, so a rep fixing three lines
 * makes one round trip instead of three (R-11).
 */
public with sharing class CpqValidator {
    /**
     * The verdict plus the catalog rows the configuration resolved to. Commit reuses the resolved
     * lines rather than looking the same codes up a second time and risking a different answer.
     */
    public class Resolved {
        public CpqDto.ValidationResponse response;
        public CPQ_Catalog_Item__c plan;
        public CPQ_Catalog_Item__c setupFeeItem;
        public Decimal setupFeeAmount;
        public List<ResolvedLine> lines = new List<ResolvedLine>();

        public Boolean isValid() {
            return response.valid;
        }
    }

    /** One line that will become an OpportunityLineItem if this configuration is committed. */
    public class ResolvedLine {
        public CPQ_Catalog_Item__c item;
        public Integer quantity;
        public Decimal unitPrice;

        public ResolvedLine(CPQ_Catalog_Item__c item, Integer quantity, Decimal unitPrice) {
            this.item = item;
            this.quantity = quantity;
            this.unitPrice = unitPrice;
        }

        public Decimal extended() {
            return unitPrice * quantity;
        }

        public Boolean isRecurring() {
            return item.Charge_Type__c == CpqConstants.CHARGE_RECURRING;
        }
    }

    public static Resolved validate(CpqDto.ConfigurationRequest request, CpqCatalog catalog) {
        Resolved resolved = new Resolved();
        CpqDto.ValidationResponse response = new CpqDto.ValidationResponse();
        response.correlationId = request.correlationId;
        resolved.response = response;

        List<CpqDto.Violation> violations = response.violations;

        resolvePlan(request, catalog, resolved, violations);
        resolveSetupFee(request, resolved, violations);
        resolveAddOns(request, catalog, resolved, violations);
        checkContractTerms(request, violations);

        response.valid = violations.isEmpty();
        if (response.valid) {
            response.totals = totals(resolved, request.contractTermMonths);
        }
        return resolved;
    }

    // =====================================================================
    // Plan
    // =====================================================================

    private static void resolvePlan(
        CpqDto.ConfigurationRequest request,
        CpqCatalog catalog,
        Resolved resolved,
        List<CpqDto.Violation> violations
    ) {
        if (String.isBlank(request.planCode)) {
            violations.add(
                violation(CpqConstants.V_PLAN_MISSING, null, null, null, 'A configuration must name exactly one plan.')
            );
            return;
        }

        CPQ_Catalog_Item__c plan = catalog.item(request.planCode);
        if (plan == null) {
            violations.add(
                violation(
                    CpqConstants.V_UNKNOWN_CATALOG_CODE,
                    request.planCode,
                    null,
                    null,
                    'No catalog item exists with code ' + request.planCode + '.'
                )
            );
            return;
        }
        if (plan.Item_Type__c != CpqConstants.TYPE_PLAN) {
            violations.add(
                violation(
                    CpqConstants.V_PLAN_MISSING,
                    request.planCode,
                    null,
                    null,
                    request.planCode + ' is a ' + plan.Item_Type__c + ', not a plan.'
                )
            );
            return;
        }
        if (!catalog.isEffective(request.planCode)) {
            violations.add(
                violation(
                    CpqConstants.V_INACTIVE_CATALOG_ITEM,
                    request.planCode,
                    null,
                    null,
                    plan.Name + ' is not available on ' + String.valueOf(catalog.effectiveDate) + '.'
                )
            );
            return;
        }

        resolved.plan = plan;

        if (!checkPriceShape(request.planPrice, request.planCode, violations)) {
            return;
        }

        // R-7. Inclusive: exactly at floor passes. The boundary is the rule, so it is stated once,
        // here, and asserted directly in the tests either side of it.
        if (request.planPrice < plan.Price_Floor__c) {
            violations.add(
                violation(
                    CpqConstants.V_PLAN_BELOW_FLOOR,
                    plan.Code__c,
                    request.planPrice,
                    plan.Price_Floor__c,
                    plan.Name + ' price is below the ' + money(plan.Price_Floor__c) + ' floor.'
                )
            );
            return;
        }

        resolved.lines.add(new ResolvedLine(plan, 1, request.planPrice));
    }

    // =====================================================================
    // Setup fee
    // =====================================================================

    private static void resolveSetupFee(
        CpqDto.ConfigurationRequest request,
        Resolved resolved,
        List<CpqDto.Violation> violations
    ) {
        if (resolved.plan == null || resolved.plan.Setup_Fee_Item__c == null) {
            return;
        }

        CPQ_Catalog_Item__c fee = resolved.plan.Setup_Fee_Item__r;
        // Absent from the request means "charge the catalog amount" rather than "waive it", so a
        // client that forgets the field cannot silently give the setup fee away.
        Decimal amount = request.setupFee == null ? fee.List_Price__c : request.setupFee;

        if (!checkPriceShape(amount, fee.Code__c, violations)) {
            return;
        }

        // R-9: waivable to zero, never marked up above catalog.
        if (amount > fee.List_Price__c) {
            violations.add(
                violation(
                    CpqConstants.V_SETUP_FEE_ABOVE_CATALOG,
                    fee.Code__c,
                    amount,
                    fee.List_Price__c,
                    'Setup fee exceeds the catalog amount of ' + money(fee.List_Price__c) + '.'
                )
            );
            return;
        }

        resolved.setupFeeItem = fee;
        resolved.setupFeeAmount = amount;
        resolved.lines.add(new ResolvedLine(fee, 1, amount));
    }

    // =====================================================================
    // Add-ons
    // =====================================================================

    private static void resolveAddOns(
        CpqDto.ConfigurationRequest request,
        CpqCatalog catalog,
        Resolved resolved,
        List<CpqDto.Violation> violations
    ) {
        if (request.addOns == null || request.addOns.isEmpty()) {
            return;
        }

        // Bound the input before doing any work on it (design doc 7.1).
        if (request.addOns.size() > CpqConstants.MAX_ADDON_LINES) {
            violations.add(
                violation(
                    CpqConstants.V_ADDON_QUANTITY_INVALID,
                    null,
                    request.addOns.size(),
                    CpqConstants.MAX_ADDON_LINES,
                    'A configuration may contain at most ' + CpqConstants.MAX_ADDON_LINES + ' add-on lines.'
                )
            );
            return;
        }

        Set<String> seen = new Set<String>();

        for (CpqDto.AddOnLine line : request.addOns) {
            if (line == null || String.isBlank(line.code)) {
                violations.add(
                    violation(CpqConstants.V_UNKNOWN_CATALOG_CODE, null, null, null, 'An add-on line has no code.')
                );
                continue;
            }

            // R-5: stacking is quantity, not repeated lines. Two lines for the same add-on would
            // otherwise aggregate into an entitlement nobody can trace back to a rep's intent.
            if (seen.contains(line.code)) {
                violations.add(
                    violation(
                        CpqConstants.V_ADDON_DUPLICATE,
                        line.code,
                        null,
                        null,
                        line.code + ' appears more than once. Stack it with quantity instead.'
                    )
                );
                continue;
            }
            seen.add(line.code);

            CPQ_Catalog_Item__c item = catalog.item(line.code);
            if (item == null) {
                violations.add(
                    violation(
                        CpqConstants.V_UNKNOWN_CATALOG_CODE,
                        line.code,
                        null,
                        null,
                        'No catalog item exists with code ' + line.code + '.'
                    )
                );
                continue;
            }
            // R-4: a second plan smuggled in as an add-on line is still a second plan.
            if (item.Item_Type__c == CpqConstants.TYPE_PLAN) {
                violations.add(
                    violation(
                        CpqConstants.V_PLAN_MULTIPLE,
                        line.code,
                        null,
                        null,
                        line.code + ' is a plan and cannot be attached as an add-on.'
                    )
                );
                continue;
            }
            if (item.Item_Type__c != CpqConstants.TYPE_ADDON) {
                violations.add(
                    violation(
                        CpqConstants.V_UNKNOWN_CATALOG_CODE,
                        line.code,
                        null,
                        null,
                        line.code + ' is not an add-on.'
                    )
                );
                continue;
            }
            if (!catalog.isEffective(line.code)) {
                violations.add(
                    violation(
                        CpqConstants.V_INACTIVE_CATALOG_ITEM,
                        line.code,
                        null,
                        null,
                        item.Name + ' is not available on ' + String.valueOf(catalog.effectiveDate) + '.'
                    )
                );
                continue;
            }

            if (line.quantity == null || line.quantity < 1) {
                violations.add(
                    violation(
                        CpqConstants.V_ADDON_QUANTITY_INVALID,
                        line.code,
                        line.quantity,
                        1,
                        'Quantity must be a positive whole number.'
                    )
                );
                continue;
            }

            Decimal unitPrice = line.unitPrice == null ? item.List_Price__c : line.unitPrice;
            if (!checkPriceShape(unitPrice, line.code, violations)) {
                continue;
            }

            // R-8: each add-on carries its own floor. A floor of zero means freely discountable.
            if (unitPrice < item.Price_Floor__c) {
                violations.add(
                    violation(
                        CpqConstants.V_ADDON_BELOW_FLOOR,
                        item.Code__c,
                        unitPrice,
                        item.Price_Floor__c,
                        item.Name + ' price is below the ' + money(item.Price_Floor__c) + ' floor.'
                    )
                );
                continue;
            }

            resolved.lines.add(new ResolvedLine(item, line.quantity, unitPrice));
        }
    }

    // =====================================================================
    // Contract terms
    // =====================================================================

    private static void checkContractTerms(CpqDto.ConfigurationRequest request, List<CpqDto.Violation> violations) {
        if (request.contractEffectiveDate == null) {
            violations.add(
                violation(
                    CpqConstants.V_EFFECTIVE_DATE_MISSING,
                    null,
                    null,
                    null,
                    'A contract effective date is required.'
                )
            );
        }

        Set<Integer> permitted = CpqConstants.permittedContractTerms();
        if (request.contractTermMonths == null || !permitted.contains(request.contractTermMonths)) {
            List<Integer> sorted = new List<Integer>(permitted);
            sorted.sort();
            violations.add(
                violation(
                    CpqConstants.V_INVALID_CONTRACT_TERM,
                    null,
                    request.contractTermMonths,
                    null,
                    'Contract term must be one of ' + String.join(sorted, ', ') + ' months.'
                )
            );
        }
    }

    // =====================================================================
    // Shared checks and helpers
    // =====================================================================

    /** R-10. Returns false when the value is unusable, so the caller skips the floor comparison. */
    private static Boolean checkPriceShape(Decimal value, String line, List<CpqDto.Violation> violations) {
        if (value == null) {
            violations.add(violation(CpqConstants.V_NEGATIVE_PRICE, line, null, null, 'A price is required.'));
            return false;
        }
        if (value < 0) {
            violations.add(violation(CpqConstants.V_NEGATIVE_PRICE, line, value, 0, 'A price cannot be negative.'));
            return false;
        }
        if (value.scale() > 2) {
            violations.add(
                violation(
                    CpqConstants.V_PRICE_PRECISION_INVALID,
                    line,
                    value,
                    null,
                    'A price may carry at most two decimal places.'
                )
            );
            return false;
        }
        return true;
    }

    /**
     * Monthly recurring, one-time, what the customer pays on day one, and the value of the whole
     * term. Computed here rather than in the client so both sides quote the same number.
     */
    public static CpqDto.Totals totals(Resolved resolved, Integer termMonths) {
        CpqDto.Totals totals = new CpqDto.Totals();
        totals.monthlyRecurring = 0;
        totals.oneTime = 0;

        for (ResolvedLine line : resolved.lines) {
            if (line.isRecurring()) {
                totals.monthlyRecurring += line.extended();
            } else {
                totals.oneTime += line.extended();
            }
        }

        totals.monthlyRecurring = totals.monthlyRecurring.setScale(2);
        totals.oneTime = totals.oneTime.setScale(2);
        totals.firstInvoice = (totals.monthlyRecurring + totals.oneTime).setScale(2);
        Integer months = termMonths == null ? 0 : termMonths;
        totals.totalContractValue = (totals.monthlyRecurring * months + totals.oneTime).setScale(2);
        return totals;
    }

    private static CpqDto.Violation violation(
        String code,
        String line,
        Decimal submitted,
        Decimal permitted,
        String message
    ) {
        return new CpqDto.Violation(code, line, submitted, permitted, message);
    }

    private static String money(Decimal amount) {
        return '$' + amount.setScale(2).format();
    }
}
