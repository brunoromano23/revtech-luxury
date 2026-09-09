#!/usr/bin/env bash
#
# End-to-end proof that the three endpoints work over HTTP, exactly as the React/NestJS platform
# would call them. No Salesforce UI is opened at any point.
#
#   ./scripts/demo.sh [org-alias] [--stage-live]
#
# Walks the full path: read the catalog, get refused for a sub-floor price, pass at the floor,
# commit to an existing Opportunity, then close it won and read the entitlements back. Then the
# overlap case — a plan that already includes a feature the rep adds again — because that is where
# binary and metered features visibly diverge.
#
# --stage-live holds back the Closed Won on the first deal and prints its URL instead, so the stage
# change can be made in the UI while recording. The overlap case still runs to completion.
#
set -euo pipefail

ORG="luxury"
STAGE_LIVE=false
for arg in "$@"; do
  case "$arg" in
    --stage-live) STAGE_LIVE=true ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *) ORG="$arg" ;;
  esac
done

# The CLI prints an update banner to stderr on every call; it is noise in a demo.
export SF_AUTOUPDATE_DISABLE=true
sf() { command sf "$@" 2>/dev/null; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

INFO=$(sf org display -o "$ORG" --json)
INSTANCE=$(echo "$INFO" | jq -r .result.instanceUrl)
TOKEN=$(echo "$INFO" | jq -r .result.accessToken)
API="$INSTANCE/services/apexrest/cpq/v1"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")
REP=$(echo "$INFO" | jq -r .result.username)

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '\033[2m%s\033[0m\n' "$1"; }

TODAY=$(date +%Y-%m-%d)
CLOSE_DATE=$(date -v+30d +%Y-%m-%d 2>/dev/null || date -d '+30 days' +%Y-%m-%d)

# An Account and an Opportunity for one scenario. This API never creates Opportunities itself, so
# the demo stands one up the way the platform's own sales process would have.
new_opportunity() {
  local name=$1 account
  account=$(sf data create record -o "$ORG" -s Account -v "Name='$name Brokerage $(date +%s)'" --json | jq -r .result.id)
  sf data create record -o "$ORG" -s Opportunity \
    -v "Name='$name' StageName='Prospecting' CloseDate=$CLOSE_DATE AccountId=$account" \
    --json | jq -r .result.id
}

# The subscription and entitlements a won deal produced, formatted identically each time so the two
# scenarios can be read side by side.
show_entitlements() {
  local opp=$1
  sf data query -o "$ORG" --json -q "SELECT Plan_Code__c, Effective_Date__c, Term_Months__c, End_Date__c, Monthly_Recurring_Revenue__c, One_Time_Total__c FROM Subscription__c WHERE Opportunity__c='$opp'" \
    | jq -r '.result.records[] | "   subscription: \(.Plan_Code__c)  \(.Effective_Date__c) -> \(.End_Date__c)  (\(.Term_Months__c) months)\n   MRR \(.Monthly_Recurring_Revenue__c)   one-time \(.One_Time_Total__c)"'
  sf data query -o "$ORG" --json -q "SELECT Feature_Code__c, Quantity__c, Metering_Type__c, Active_From__c, Active_To__c FROM Customer_Entitlement__c WHERE Source_Opportunity__c='$opp' ORDER BY Feature_Code__c" \
    | jq -r '.result.records[] | "   \(.Feature_Code__c | .[0:26] + (" " * (26 - length))) \(if .Quantity__c then "qty \(.Quantity__c)" else "enabled" end)   [\(.Metering_Type__c)]  \(.Active_From__c) -> \(.Active_To__c)"'
}

# Status code and body from one call, so the demo can show both.
call() {
  local method=$1 url=$2 data=${3:-}
  local out
  if [ -n "$data" ]; then
    out=$(curl -s -w '\n%{http_code}' -X "$method" "${AUTH[@]}" -d "$data" "$url")
  else
    out=$(curl -s -w '\n%{http_code}' -X "$method" "${AUTH[@]}" "$url")
  fi
  STATUS=$(echo "$out" | tail -1)
  BODY=$(echo "$out" | sed '$d')
}

# ---------------------------------------------------------------- 1. catalog
bold "1. GET /catalog — what the platform renders the configurator from"
call GET "$API/catalog"
note "HTTP $STATUS"
echo "$BODY" | jq '{catalogVersion, permittedContractTerms,
  plans: [.plans[] | {code, listPrice, priceFloor, setupFee: .setupFee.listPrice,
                      includes: [.includedFeatures[] | "\(.featureCode)\(if .quantity then " x\(.quantity)" else "" end)"]}],
  addOns: [.addOns[] | {code, listPrice, priceFloor, chargeType, grants: .featureCode}]}'

# --------------------------------------------------------- 2. validate: refused
bold "2. POST /validate — Brand at \$425 with Contacts at \$70. Both below floor."
call POST "$API/configurations/validate" "$(cat <<JSON
{
  "actingRepEmail": "$REP",
  "planCode": "PLAN_BRAND",
  "planPrice": 425.00,
  "addOns": [{ "code": "ADDON_CONTACTS_500", "quantity": 1, "unitPrice": 70.00 }],
  "contractEffectiveDate": "$TODAY",
  "contractTermMonths": 12
}
JSON
)"
note "HTTP $STATUS — a refusal is still a successful answer to \"is this valid?\""
echo "$BODY" | jq '{valid, violations: [.violations[] | {code, line, submitted, permitted}]}'

# ---------------------------------------------------------- 3. validate: passes
bold "3. POST /validate — Brand at exactly \$450.00, the floor. Inclusive, so it passes."
call POST "$API/configurations/validate" "$(cat <<JSON
{
  "actingRepEmail": "$REP",
  "planCode": "PLAN_BRAND",
  "planPrice": 450.00,
  "setupFee": 1000.00,
  "addOns": [{ "code": "ADDON_CONTACTS_500", "quantity": 1, "unitPrice": 100.00 }],
  "contractEffectiveDate": "$TODAY",
  "contractTermMonths": 12
}
JSON
)"
note "HTTP $STATUS"
echo "$BODY" | jq '{valid, totals}'

# --------------------------------------------------- 4. an Opportunity to commit to
bold "4. An Opportunity that already exists — this API never creates one"
OPP_ID=$(new_opportunity 'Demo CPQ Deal')
note "Opportunity $OPP_ID"

# ------------------------------------------------------ 5. commit: refused (422)
bold "5. POST /commit — sub-floor, skipping /validate entirely"
call POST "$API/opportunities/$OPP_ID/commit" "$(cat <<JSON
{
  "actingRepEmail": "$REP",
  "idempotencyKey": "demo-refused-$(date +%s)",
  "planCode": "PLAN_BRAND",
  "planPrice": 400.00,
  "contractEffectiveDate": "$TODAY",
  "contractTermMonths": 12
}
JSON
)"
note "HTTP $STATUS — the client is not obliged to call /validate first, so commit re-checks."
echo "$BODY" | jq '{code, violations: [.violations[] | {code, submitted, permitted}]}'
note "Line items written: $(sf data query -o "$ORG" -q "SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId='$OPP_ID'" --json | jq -r .result.totalSize)"

# ------------------------------------------------------- 6. commit: accepted (200)
KEY="demo-commit-$(date +%s)"
bold "6. POST /commit — Brand at \$450, plus Contacts (500) x1 and a Design Refresh"
call POST "$API/opportunities/$OPP_ID/commit" "$(cat <<JSON
{
  "actingRepEmail": "$REP",
  "idempotencyKey": "$KEY",
  "planCode": "PLAN_BRAND",
  "planPrice": 450.00,
  "setupFee": 1000.00,
  "addOns": [
    { "code": "ADDON_CONTACTS_500",    "quantity": 1, "unitPrice": 100.00 },
    { "code": "ADDON_DESIGN_REFRESH",  "quantity": 1, "unitPrice": 750.00 }
  ],
  "contractEffectiveDate": "$TODAY",
  "contractTermMonths": 12
}
JSON
)"
note "HTTP $STATUS"
echo "$BODY" | jq '{opportunityId, replayed, lineCount: (.lineItemIds | length), totals}'

bold "   Opportunity Products now on the deal"
sf data query -o "$ORG" --json -q "SELECT CPQ_Catalog_Item__r.Code__c, Quantity, UnitPrice, TotalPrice, CPQ_Charge_Type__c FROM OpportunityLineItem WHERE OpportunityId='$OPP_ID' ORDER BY CPQ_Charge_Type__c, UnitPrice DESC" \
  | jq -r '.result.records[] | "   \(.CPQ_Catalog_Item__r.Code__c | .[0:26] + (" " * (26 - length))) qty \(.Quantity)  @ \(.UnitPrice)  = \(.TotalPrice)  [\(.CPQ_Charge_Type__c)]"'

# ------------------------------------------------------------ 7. idempotency
bold "7. POST /commit — the identical request again, as a retried call would be"
call POST "$API/opportunities/$OPP_ID/commit" "$(cat <<JSON
{
  "actingRepEmail": "$REP",
  "idempotencyKey": "$KEY",
  "planCode": "PLAN_BRAND",
  "planPrice": 450.00,
  "setupFee": 1000.00,
  "addOns": [
    { "code": "ADDON_CONTACTS_500",    "quantity": 1, "unitPrice": 100.00 },
    { "code": "ADDON_DESIGN_REFRESH",  "quantity": 1, "unitPrice": 750.00 }
  ],
  "contractEffectiveDate": "$TODAY",
  "contractTermMonths": 12
}
JSON
)"
note "HTTP $STATUS"
echo "$BODY" | jq '{replayed, lineCount: (.lineItemIds | length)}'
note "Line items still on the deal: $(sf data query -o "$ORG" -q "SELECT COUNT() FROM OpportunityLineItem WHERE OpportunityId='$OPP_ID'" --json | jq -r .result.totalSize)"

# --------------------------------------------------------- 8. Closed Won → entitlements
if [ "$STAGE_LIVE" = true ]; then
  bold "8. Closed Won — held back so the stage change can be made on camera"
  note "   $INSTANCE/lightning/r/Opportunity/$OPP_ID/view"
  note "   Move it to Closed Won in the UI; the entitlements build behind that save."
else
  bold "8. Close the deal won — Apex builds the durable entitlements"
  sf data update record -o "$ORG" -s Opportunity -i "$OPP_ID" -v "StageName='Closed Won'" --json >/dev/null
  note "   Brand includes 500 contacts, the add-on stacks 500 more"
  show_entitlements "$OPP_ID"
  note "   Design Refresh was billed above and grants nothing — its catalog item has no feature."
fi

# ------------------------------------------- 9. the overlap case, on a second deal
bold "9. The overlap case — All In already includes Competitor Analysis, and the rep adds it again"
ALLIN_OPP=$(new_opportunity 'Demo CPQ Deal — All In')
note "Opportunity $ALLIN_OPP"

call POST "$API/opportunities/$ALLIN_OPP/commit" "$(cat <<JSON
{
  "actingRepEmail": "$REP",
  "idempotencyKey": "demo-allin-$(date +%s)",
  "planCode": "PLAN_ALL_IN",
  "planPrice": 2495.00,
  "setupFee": 2500.00,
  "addOns": [
    { "code": "ADDON_CONTACTS_500",        "quantity": 3, "unitPrice": 100.00 },
    { "code": "ADDON_COMPETITOR_ANALYSIS", "quantity": 1, "unitPrice": 150.00 },
    { "code": "ADDON_DESIGN_REFRESH",      "quantity": 1, "unitPrice": 750.00 }
  ],
  "contractEffectiveDate": "$TODAY",
  "contractTermMonths": 12
}
JSON
)"
note "HTTP $STATUS"
echo "$BODY" | jq '{lineCount: (.lineItemIds | length), totals}'

sf data update record -o "$ORG" -s Opportunity -i "$ALLIN_OPP" -v "StageName='Closed Won'" --json >/dev/null
show_entitlements "$ALLIN_OPP"
note "   Competitor analysis came from the plan AND the add-on — entitled once, because it is Binary."
note "   Contacts: 1,000 from the plan + 500 x 3 from the add-on = 2,500, because they are Metered."
note "   Design Refresh is billed on the deal and grants nothing, in both scenarios."

# ---------------------------------------------------------------- 10. logs
bold "10. What support sees afterwards"
note "   Nebula Logger. Correlation_Id__c is the one field added to it — the join key the caller shares."
sf data query -o "$ORG" --json -q "SELECT LoggingLevel__c, EntryScenario__r.Name, Correlation_Id__c FROM LogEntry__c WHERE Correlation_Id__c != NULL ORDER BY CreatedDate DESC LIMIT 8" \
  | jq -r '.result.records[] | "   \(.LoggingLevel__c // "-" | .[0:6] + (" " * (6 - length))) \(.EntryScenario__r.Name // "-" | .[0:40] + (" " * (40 - length))) \(.Correlation_Id__c // "-" | .[0:13])"'

bold "Done."
if [ "$STAGE_LIVE" = true ]; then
  echo "   Brand deal  — staged at Prospecting, close it on camera:"
else
  echo "   Brand deal  — won:"
fi
echo "     $INSTANCE/lightning/r/Opportunity/$OPP_ID/view"
echo "   All In deal — won:"
echo "     $INSTANCE/lightning/r/Opportunity/$ALLIN_OPP/view"
