# Custom CPQ on Salesforce — Luxury Presence RevTech

A headless CPQ layer: Salesforce owns the catalog, enforces the price floors, and produces the
durable entitlements that feature gating and billing consume. The rep-facing configurator lives on
the React/NestJS platform and talks to this over REST. Nobody opens a Salesforce screen in this
workflow.

Case study submission for the Senior Salesforce Developer role.
**Solution design: [`documents/`](documents/)** · **Apex: [`force-app/main/default/classes/`](force-app/main/default/classes/)**

---

## Get it running

```bash
sf org login web -a luxurycpq -s                          # any Developer Edition org
sf project deploy start -d force-app
sf org assign permset -n CPQ_Integration_User -n CPQ_Catalog_Admin
sf apex run --file scripts/apex/seed-catalog.apex         # the catalog from the brief
sf apex run --file scripts/apex/create-integration-user.apex   # the API principal
sf apex run test --test-level RunLocalTests --code-coverage
./scripts/demo.sh luxurycpq                               # end to end over HTTP
```

The permission set assignment is not optional. Fields deployed through the Metadata API carry no
field-level security for any profile, and every query and DML in this codebase runs in user mode —
so without it, even a System Administrator sees nothing.

**Current state:** 66 Apex tests written for this project, all passing, 78-100% coverage on
its own classes. `RunLocalTests` now runs ~1,480 tests because the two unlocked packages have
no namespace and their suites count as local; 66 is the honest number for what this project wrote.
The REST surface is additionally exercised over HTTP from Postman as the integration user — see
[`postman/`](postman/), which found five defects a passing Apex suite could not see.

---

## The API

```
GET  /services/apexrest/cpq/v1/catalog?effectiveDate=yyyy-mm-dd
POST /services/apexrest/cpq/v1/configurations/validate
POST /services/apexrest/cpq/v1/opportunities/{opportunityId}/commit
```

`validate` returns **200** even when it refuses — the question "is this sellable?" was answered
successfully and the answer was no. `commit` returns **422** when it refuses, because there the
caller asked us to write something and we declined. That asymmetry is deliberate and documented, so
a client developer does not have to guess it twice.

`scripts/demo.sh` walks the whole path with curl: catalog → refused at $425 → passes at exactly the
$450 floor → refused commit writes nothing → accepted commit → retried commit replays instead of
double-writing → Closed Won → entitlements → the log rows support would read. It then runs the
overlap case on a second deal — All In, which already includes Competitor Analysis, with the rep
adding Competitor Analysis again and Contacts ×3 — where the binary feature resolves to enabled
once and the metered one accumulates to 2,500.

`--stage-live` holds back the Closed Won on the first deal and prints its URL instead, so the stage
change can be made in the UI rather than by the script.

---

## What the code does

| Class | Responsibility |
|---|---|
| `CpqCatalog` / `CpqCatalogService` | Loads the catalog once per request and resolves it against an effective date. Keeps inactive items, so a typo and a withdrawn product are different errors. |
| `CpqValidator` | Every commercial rule. Pure — no SOQL, no DML — which is what lets `/validate` be called on every keystroke and lets `/commit` re-run the identical check. |
| `CpqCommitService` | The transactional write: one savepoint, replaces only its own prior lines, idempotent by key. |
| `CpqEntitlementService` | Closed Won aggregation. Two SOQL and two DML whether it runs for 1 record or 200. |
| `OpportunityCpqHandler` | Fires on the transition into Closed Won only. Fails the individual record, not the batch. |
| `OpportunityCpqEntitlementAction` | Binds that handler to the Trigger Actions Framework. Deliberately thin — routing is the framework's job, the rules are the handler's. |
| `CpqLogger` | A thin adapter over Nebula Logger. Logs go through the event bus, so a failed commit's log survives the rollback that erases everything else. |
| `CpqCatalogSeed` | The reference catalog, defined once and shared by the tests and the seed script. |

### Three decisions worth knowing before reading it

**`Product2` exists alongside a custom catalog because it has to.** `OpportunityLineItem` cannot be
inserted without a `PricebookEntryId`. `CPQ_Catalog_Item__c` stays the source of truth for the CPQ
rules — floors, included features, charge type, effective windows — none of which `Product2` can
express.

**Design Refresh grants nothing because its `Feature__c` is null.** It is billable and must never
reach feature gating. There is no `if (code == 'ADDON_DESIGN_REFRESH')` anywhere in the codebase; the
absence of a feature link is the whole mechanism, so the next non-entitling add-on needs no
deployment. Likewise, whether a feature accumulates is `CPQ_Feature__c.Metering_Type__c`, not a
branch — which is why Competitor Analysis resolves to enabled *once* when it arrives from both the
plan and an add-on, while contacts add up to 1,000.

**Idempotency is enforced by the database.** `Idempotency_Key__c` is a unique External Id. Querying
for an existing key and then inserting would pass every test in this repo and still lose a race in
production.

---

## Repository layout

```
documents/                     solution design (Markdown source + generated PDF)
force-app/main/default/
  classes/                     Apex: services, REST resources, tests
  objects/                     6 custom objects, 1 custom metadata type, plus one field added
                               to Nebula Logger's LogEntryEvent__e / LogEntry__c
  permissionsets/              CPQ_Integration_User (least privilege), CPQ_Catalog_Admin (RevOps)
  connectedApps/               RevTech CPQ Platform — client credentials flow
  customMetadata/              trigger action registration, Nebula field mapping, CPQ settings
  triggers/                    OpportunityTrigger (one line; routing is metadata)
postman/                       the REST surface as the platform calls it, with assertions
scripts/
  demo.sh                      end-to-end HTTP walkthrough
  apex/seed-catalog.apex       loads the catalog from the brief
  apex/create-integration-user.apex   provisions the API principal
```

## Scope

Built: the catalog, server-side floor enforcement, commit to Opportunity, Closed Won entitlement
automation, and the logging that makes all of it supportable.

Two open-source frameworks are used rather than hand-rolled equivalents: the **Trigger Actions
Framework** for trigger routing, and **Nebula Logger** for logging.

Not built, by instruction: any UI, Opportunity creation, live callouts to billing or feature
gating, approval routing for sub-floor pricing, and anything touching `Quote` / `QuoteLineItem` —
contracts are generated in PandaDoc, so `OpportunityLineItem` is the source of truth for what is
being sold. OAuth *is* built: a Connected App using the client credentials flow, running as a
least-privilege integration user.

Add-on prices and floors are assumed values pending RevOps confirmation. They are catalog records,
so changing them is an org edit rather than a deployment.
