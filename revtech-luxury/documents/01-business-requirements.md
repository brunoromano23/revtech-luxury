# Business Requirements Document
## Custom CPQ on Salesforce — Plans, Add-Ons & Entitlements

| | |
|---|---|
| **Client** | Luxury Presence — RevTech |
| **Project** | Custom CPQ solution on Salesforce (headless) |
| **Document** | Business Requirements Document (BRD) |
| **Version** | 1.0 |
| **Date** | 7 September 2026 |
| **Author** | Bruno Romano — Senior Salesforce Developer (candidate) |
| **Status** | For review |
| **Audience** | RevTech engineering, RevOps, Sales leadership |
| **Related** | `02-solution-design.md` (data model, ERD, API contract, security) |

---

## 1. Executive Summary

Luxury Presence sells three subscription plans — **Launch**, **Brand** and **All In** — each with a fixed feature set and a one-time setup fee, plus three optional add-on products. Reps need to configure a deal (pick a plan, negotiate the price within limits, stack add-ons, set contract terms) and push the result onto an existing Opportunity.

The interface reps use is being built on Luxury Presence's internal React/NestJS platform. **Salesforce is not the UI.** Salesforce is the system of record for the catalog, the authority that enforces commercial guardrails, and the origin of the durable entitlement records that downstream feature-gating and billing systems depend on.

This document defines *what the business needs*. It does not specify the implementation; that is `02-solution-design.md`.

The single most important consequence of the headless architecture drives everything below: **Salesforce cannot rely on any client-side control.** Every rule in Section 6 must hold when the caller is a script, a Postman request, or a bug in the platform — not just when it is the intended React UI.

### 1.1 Business Context

Luxury Presence is a real-estate marketing and growth platform serving 18,000+ agents, teams and brokerages, with websites, listing marketing, CRM, advertising and AI tooling consolidated under the Presence Platform. Its GTM systems are being re-platformed onto an internal React/NestJS stack, with Salesforce retained as the system of record and business-logic layer behind those tools rather than as a rep-facing application.

Luxury Presence does **not** license Salesforce CPQ. The configure-price-quote capability described here is being built in-house on custom objects and Apex. This is a deliberate build decision, and it sets the boundary of this project: we are building the CPQ engine, not configuring a packaged one.

---

## 2. Business Problem

| # | Problem | Business impact |
|---|---|---|
| P-1 | Plan pricing, floors, setup fees and included features are not held in one governed place. | Reps quote from spreadsheets and tribal knowledge; pricing drifts between reps. |
| P-2 | Discounting is not enforced by any system. | Deals close below the approved floor; margin leaks with no audit trail of who did it. |
| P-3 | What a customer actually bought is reconstructed by hand from the deal record. | Provisioning and billing rely on manual interpretation; overlap between plan-included features and add-ons is routinely mis-counted. |
| P-4 | Downstream systems have no reliable, machine-readable source for entitlements. | Feature gating and billing each build their own interpretation of the same deal, and disagree. |
| P-5 | The new React/NestJS CPQ has no server-side contract to build against. | The platform team cannot ship without duplicating pricing logic in the front end — where it can be bypassed. |

---

## 3. Objectives & Success Measures

| # | Objective | Success measure |
|---|---|---|
| O-1 | One governed source of truth for the sellable catalog. | 100% of quoted configurations reference catalog records; no free-text products. |
| O-2 | Price floors enforced server-side, unconditionally. | Zero committed Opportunity Products below floor, measured against the catalog floor effective on the commit date. |
| O-3 | A stable, versioned API the platform team can build against. | Platform team integrates catalog, validate and commit without replicating pricing rules client-side. |
| O-4 | A durable, correctly aggregated entitlement record per customer. | Entitlement quantities reconcile to plan-included quantity + add-on quantity for 100% of Closed Won deals (see §7.3). |
| O-5 | Operational visibility into the integration. | Every commit, validation failure and error is attributable to an actor, a correlation ID and a timestamp. |

---

## 4. Scope

### 4.1 In Scope

| # | Capability | Summary |
|---|---|---|
| S-1 | **Catalog access** | Salesforce exposes current plans, list prices, floors, setup fees, included features and add-ons to the platform. |
| S-2 | **Price floor validation** | Salesforce accepts a proposed configuration and returns a structured pass/fail with per-line reasons. Server-side, stateless, no side effects. |
| S-3 | **Commit to Opportunity** | Salesforce accepts a finalised configuration plus an existing Opportunity Id and writes the Opportunity Products (plan, setup fee, add-ons) and contract terms, atomically. |
| S-4 | **Closed Won entitlement automation** | When an Opportunity reaches Closed Won, Apex creates the durable subscription and entitlement records for that customer. |
| S-5 | **Logging & monitoring** | Successful commits, validation failures and errors are logged and monitorable. Approach documented; full alerting stack not built. |

### 4.2 Out of Scope

Taken directly from the brief, restated so the boundary is unambiguous:

| # | Excluded | Note |
|---|---|---|
| X-1 | Any UI or front-end build. | Endpoints proven via anonymous Apex / curl. |
| X-2 | Live OAuth implementation. | Auth *pattern* documented in the solution design; no Connected App handshake built. |
| X-3 | Opportunity creation. | The Opportunity exists; the API accepts its Id. |
| X-4 | Live integration with feature-gating or billing. | The data model must *support* them (§8); no callouts built. |
| X-5 | Approval processes or manager workflow for sub-floor pricing. | A hard pass/fail is the requirement. Not a request-approval loop. |
| X-6 | Salesforce `Quote` / `QuoteLineItem`. | Contracts are generated in PandaDoc. `OpportunityLineItem` is the source of truth for what is being sold. |
| X-7 | Exhaustive field-level modelling. | Only fields that carry a stated requirement. |
| X-8 | Renewals, amendments, co-terming, proration, cancellations. | Acknowledged in §11 as the next phase; the model must not preclude them. |

---

## 5. Actors & Stakeholders

| Actor | Type | Interaction |
|---|---|---|
| **Sales Rep** | Human | Configures and commits deals through the React/NestJS CPQ. Never opens Salesforce for this workflow. |
| **RevTech Platform** | System | The React/NestJS application. The only intended caller of the CPQ API. Authenticates as a dedicated integration principal. |
| **RevOps Admin** | Human | Maintains the catalog — plans, prices, floors, setup fees, add-ons, effective dates — in Salesforce. |
| **Feature-Gating Service** | Downstream system | Reads entitlements to decide what a customer's account can do. |
| **Billing System** | Downstream system | Reads contracted lines and terms to invoice. |
| **RevTech Engineer / Support** | Human | Monitors integration health; investigates failed commits. |

**Note on the rep's identity.** Reps act *through* the platform, which authenticates as a single integration principal. Salesforce therefore sees one API user, not the rep. The rep's identity must still be carried in the request and recorded on the committed records and logs (§9), otherwise O-5 is unachievable and no discount is attributable to a person.

---

## 6. Business Rules

Numbered, testable, and each one traceable to a test in the prototype.

### 6.1 Catalog

| ID | Rule |
|---|---|
| BR-01 | The catalog is maintained in Salesforce by RevOps and is the single source of truth for prices, floors, setup fees and included features. |
| BR-02 | Every catalog item has an `Active` state and an effective date window. Only items active on the configuration's effective date may be quoted. |
| BR-03 | Every catalog item carries a stable, human-readable code (e.g. `PLAN_BRAND`, `ADDON_CONTACTS_500`) that is immutable once published. Downstream systems key on the code, never on the Salesforce Id. |
| BR-04 | Changing a price or floor in the catalog must not retroactively alter already-committed Opportunity Products or existing entitlements. |

### 6.2 Configuration

| ID | Rule |
|---|---|
| BR-05 | A configuration contains **exactly one** plan. Zero plans or multiple plans is invalid. |
| BR-06 | A configuration contains zero or more add-on lines. |
| BR-07 | Add-on quantity must be a positive integer (≥ 1). |
| BR-08 | The same add-on may appear only once per configuration; stacking is expressed through quantity, not repeated lines. |
| BR-09 | Add-ons that duplicate a plan-included feature are **explicitly permitted**, in both directions: a plan without Competitor Analysis may add it, and a plan that already includes a contact pack may stack more. This is intentional, not an error. |

### 6.3 Pricing & Floors

| ID | Rule |
|---|---|
| BR-10 | **The plan's negotiated monthly price must be greater than or equal to that plan's price floor.** This is the core commercial guardrail. Violation fails the configuration. |
| BR-11 | No upper bound is enforced on the plan price. Uplift above list is permitted and recorded. *(Confirmation requested — OQ-1.)* |
| BR-12 | The setup fee defaults to the plan's catalog amount. It may be discounted down to $0 (fully waived) but may not exceed the catalog amount. |
| BR-13 | Each add-on has its own price floor in the catalog. A negotiated add-on price below its floor fails the configuration. An add-on with a floor of $0 is freely discountable. |
| BR-14 | All prices are USD. Monetary values are validated to two decimal places. Negative prices are invalid. |
| BR-15 | Validation reports **every** violation in one response, not just the first. A rep fixing three lines should need one round-trip, not three. |

### 6.4 Contract Terms

| ID | Rule |
|---|---|
| BR-16 | A contract effective date is required. |
| BR-17 | The contract term in months must be one of the values configured as permitted (initially 12, 24, 36). |
| BR-18 | Contract term and effective date are recorded on the Opportunity and carried onto the entitlement records; they define the entitlement's active window. |

### 6.5 Commit

| ID | Rule |
|---|---|
| BR-19 | Commit **re-runs the full validation server-side**. A prior successful validate call is never trusted — it may be stale, or may never have happened. |
| BR-20 | Commit is **atomic**: either the plan line, setup fee line, all add-on lines and the Opportunity term fields are written, or nothing is. No partial configurations. |
| BR-21 | Commit targets an Opportunity that already exists. A missing, inaccessible or invalid Id is a clean, typed error — never an unhandled exception. |
| BR-22 | Commit is rejected if the target Opportunity is already Closed (Won or Lost). Closed deals are immutable to this API. |
| BR-23 | Re-committing to the same Opportunity **replaces** the lines previously written by this API, rather than appending. Re-quoting is the normal case, and duplicated lines would corrupt both billing and entitlements. Lines added on the Opportunity by other means are left untouched. |
| BR-24 | Commit is idempotent: the same request submitted twice (same idempotency key) produces one result, not two sets of lines. |

### 6.6 Closed Won & Entitlements

| ID | Rule |
|---|---|
| BR-25 | When an Opportunity moves to Closed Won, entitlement records are created for the customer from the committed Opportunity Products. |
| BR-26 | Entitlement quantity per feature is the **sum** of the quantity included in the plan and the quantity from any matching add-on lines. See the worked example in §7.3. |
| BR-27 | Entitlement creation is idempotent and bulk-safe: a bulk stage update across many Opportunities, or an Opportunity re-saved at Closed Won, must not duplicate entitlements. |
| BR-28 | Entitlements are **durable**. They are not deleted or rewritten when catalog prices change or when the Opportunity is edited afterwards. Corrections are made by superseding a record, preserving history. |
| BR-29 | Only recurring, feature-bearing items produce entitlements. The setup fee is a billable one-time charge and grants no entitlement. |

---

## 7. The Commercial Catalog

The business facts this system is built around. These are requirements, not sample data.

### 7.1 Plans

| Plan | Code | List price (monthly) | Price floor (monthly) | Setup fee (one-time) | Max discount |
|---|---|---|---|---|---|
| Launch | `PLAN_LAUNCH` | $295.00 | $250.00 | $500.00 | 15.3% |
| Brand | `PLAN_BRAND` | $595.00 | $450.00 | $1,000.00 | 24.4% |
| All In | `PLAN_ALL_IN` | $2,495.00 | $2,000.00 | $2,500.00 | 19.8% |

*Max discount is derived, shown for context. The system enforces the floor, not a discount percentage — floors are the business's stated control (BR-10).*

### 7.2 Plan-Included Features

| Feature | Code | Launch | Brand | All In |
|---|---|---|---|---|
| Website hosting | `FEAT_WEBSITE_HOSTING` | ✔ | ✔ | ✔ |
| Listing feeds | `FEAT_LISTING_FEEDS` | ✔ | ✔ | ✔ |
| Competitor analysis | `FEAT_COMPETITOR_ANALYSIS` | — | — | ✔ |
| Contact pack (500 contacts) | `FEAT_CONTACTS` | — | ×1 (500) | ×2 (1,000) |

Website hosting and listing feeds are **binary** features: a customer either has them or does not. The contact pack is a **metered** feature: it carries a quantity that accumulates. The data model must distinguish the two, because feature gating asks a different question of each ("is it on?" vs "how many?").

### 7.3 Add-Ons

| Add-on | Code | Maps to feature | Charge type | List price | Price floor |
|---|---|---|---|---|---|
| Design Refresh | `ADDON_DESIGN_REFRESH` | *(none — a service, not an entitlement)* | One-time | $750.00 † | $600.00 † |
| Competitor Analysis | `ADDON_COMPETITOR_ANALYSIS` | `FEAT_COMPETITOR_ANALYSIS` | Recurring monthly | $150.00 † | $120.00 † |
| Contacts (500) | `ADDON_CONTACTS_500` | `FEAT_CONTACTS` (qty 500) | Recurring monthly | $100.00 † | $80.00 † |

† **AS-1 — assumed values.** The brief specifies add-on products but not their prices, floors or charge types. These are placeholders so the prototype is demonstrable end to end. They live in catalog records and are changed by RevOps without a code deployment. **RevOps to confirm before go-live (OQ-2).**

**Design Refresh is deliberately modelled as sellable but non-entitling.** It is a one-off design service, not a capability to gate. It must reach billing and must *not* reach the feature-gating system. This is exactly the distinction BR-29 exists to make.

### 7.4 Worked Example — Overlap and Aggregation

The case the brief calls out, and the one the model must provably get right:

> A customer buys **Brand** ($595/mo, includes Contact pack ×1 = 500 contacts) and adds **Contacts (500) × 1**.

| Feature | From plan | From add-ons | **Total entitlement** |
|---|---|---|---|
| Website hosting | enabled | — | **enabled** |
| Listing feeds | enabled | — | **enabled** |
| Contacts | 500 | 500 | **1,000** |

A second case, to prove aggregation is not hard-coded to two:

> **All In** ($2,495/mo, includes Contact pack ×2 = 1,000 contacts) + **Contacts (500) × 3** + **Competitor Analysis × 1**.

| Feature | From plan | From add-ons | **Total entitlement** |
|---|---|---|---|
| Website hosting | enabled | — | **enabled** |
| Listing feeds | enabled | — | **enabled** |
| Competitor analysis | enabled | enabled (duplicate) | **enabled** — not double-counted |
| Contacts | 1,000 | 1,500 | **2,500** |

Binary features do not accumulate; metered features do. Both plan and add-on can be the source of the same feature, and neither is privileged.

---

## 8. Functional Requirements

### 8.1 Catalog Access (S-1)

| ID | Requirement |
|---|---|
| FR-01 | The platform can retrieve the full sellable catalog in a single call: plans with list price, floor, setup fee and included features; add-ons with list price, floor, charge type and mapped feature. |
| FR-02 | The response returns only items active on the requested effective date; the caller may pass a date, defaulting to today. |
| FR-03 | Every returned item includes its stable code (BR-03) so the platform can reference items without storing Salesforce Ids. |
| FR-04 | The response is safe to cache by the platform and carries a version or timestamp so the platform can detect catalog changes. |
| FR-05 | The catalog is editable by RevOps without a code deployment. |

### 8.2 Price Floor Validation (S-2)

| ID | Requirement |
|---|---|
| FR-06 | The platform can submit a proposed configuration — plan, negotiated price, setup fee, add-ons with quantity and price, contract terms — and receive a pass/fail result. |
| FR-07 | The result is structured, not prose: a boolean outcome plus a list of violations, each with a machine-readable code, the offending line, the submitted value and the permitted value. |
| FR-08 | All violations are returned in one response (BR-15). |
| FR-09 | Validation has **no side effects**. It creates, updates and deletes nothing, and may be called as often as the platform likes while a rep is typing. |
| FR-10 | Validation covers every rule in §6.2, §6.3 and §6.4 — not the plan floor alone. |
| FR-11 | Unknown or inactive catalog codes are a validation failure with a distinct error code, not a generic error. |

### 8.3 Commit to Opportunity (S-3)

| ID | Requirement |
|---|---|
| FR-12 | The platform can submit a finalised configuration together with an existing Opportunity Id. |
| FR-13 | Salesforce writes one Opportunity Product per configured item: the plan (recurring), the setup fee (one-time) and each add-on, at the confirmed price and quantity. |
| FR-14 | Contract effective date and term are recorded on the Opportunity. |
| FR-15 | Commit re-validates before writing and refuses to write on any violation (BR-19), returning the same structured violation payload as FR-07. |
| FR-16 | Commit is atomic (BR-20), idempotent (BR-24), and replaces prior CPQ-written lines (BR-23). |
| FR-17 | The response returns the Opportunity Id, the created line Ids, the computed totals (monthly recurring, one-time, first-invoice and total contract value) and the correlation ID for support. |
| FR-18 | Committed lines retain a durable link back to the catalog item and the feature they carry, so §8.4 does not have to re-derive them by name matching. |

### 8.4 Closed Won Automation (S-4)

| ID | Requirement |
|---|---|
| FR-19 | On transition to Closed Won, Apex creates a subscription record for the Opportunity's Account, carrying the contract effective date, term and end date. |
| FR-20 | Apex creates one entitlement record per distinct feature, with the aggregated quantity per BR-26 and the worked examples in §7.3. |
| FR-21 | The automation is bulk-safe: it must behave correctly for a single record and for a 200-record batch update, within governor limits, with no SOQL or DML inside loops. |
| FR-22 | The automation is idempotent (BR-27): re-saving an already-Closed-Won Opportunity creates nothing new. |
| FR-23 | The automation fires only on the *transition into* Closed Won, not on every save of a won Opportunity. |
| FR-24 | A failure in entitlement creation must be logged and surfaced (§9); it must not silently swallow the error, and must not leave a half-built subscription. |
| FR-25 | Implemented in **Apex**, not a Record-Triggered Flow. *(Explicit instruction in the brief.)* |

### 8.5 Logging & Monitoring (S-5)

| ID | Requirement |
|---|---|
| FR-26 | Every API call records: correlation ID, endpoint, acting rep, integration principal, target Opportunity, outcome, duration and timestamp. |
| FR-27 | Validation failures are logged with their violation codes — sub-floor attempts are commercially interesting data, not just noise. |
| FR-28 | Unhandled errors are logged with the stack trace and enough request context to reproduce, without persisting sensitive payload data indiscriminately. |
| FR-29 | Logs are queryable by correlation ID, Opportunity, rep and date range, so support can answer "what happened to this deal?" in one query. |
| FR-30 | Integration health — error rate, commit volume, failure reasons — is monitorable, and a sustained error rate raises an alert. Approach documented in the solution design; alerting stack not built (X-4). |
| FR-31 | Log retention is bounded; logs are pruned on a defined schedule so the object does not grow without limit. |

---

## 9. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-01 | **Bulk-safe.** All Apex operates on collections. No SOQL, DML or callouts inside loops. Trigger logic correct for 200-record batches. |
| NFR-02 | **Tested.** Meaningful unit test coverage of the business logic — positive paths, boundary conditions (price exactly at floor), negative paths and bulk. Coverage as evidence of tested logic, not as a number to hit. |
| NFR-03 | **Secure by construction.** The API is called by systems and people not under our control. CRUD/FLS enforced, sharing respected, all SOQL bound — never string-concatenated. Detailed in the solution design. |
| NFR-04 | **Least privilege.** The integration principal has exactly the object and field access this API needs, granted by permission set, and no more. |
| NFR-05 | **Predictable contract.** Typed request and response shapes, stable error codes, an explicitly versioned URI. Changes are additive; breaking changes get a new version. |
| NFR-06 | **Performance.** Catalog reads and validation respond well inside the platform's request budget and stay within Salesforce governor limits at expected volume. Validation performs no DML and minimal SOQL. |
| NFR-07 | **Auditable.** Every committed configuration can be traced to a rep, a timestamp and a correlation ID; every sub-floor attempt is recorded. |
| NFR-08 | **Resilient to bad input.** Malformed JSON, missing fields, wrong types, unknown codes and invalid Ids all return typed errors with the right HTTP status — never an unhandled exception or a raw Apex stack trace to the caller. |
| NFR-09 | **Deployable.** All metadata and Apex source-controlled and deployable to a scratch org or sandbox from this repository. |

---

## 10. Data Requirements

Object-level design is in `02-solution-design.md`. These are the business-level constraints it must satisfy.

| ID | Requirement |
|---|---|
| DR-01 | The catalog is held in **custom objects**, not hard-coded and not in Salesforce CPQ (not licensed). RevOps edits records; engineering is not in the loop for a price change. |
| DR-02 | Because `OpportunityLineItem` cannot be created without a `PricebookEntryId`, each sellable catalog item maps to a `Product2` with a `PricebookEntry`. This is a platform constraint, not a design preference — the custom catalog stays the source of truth for CPQ rules (floors, included features, charge type), and `Product2`/`PricebookEntry` is the commercial record the platform requires. |
| DR-03 | The feature catalog is separate from the product catalog. Products are what we *sell*; features are what a customer is *entitled to*. Competitor Analysis is both, and the model must express that without conflating the two. |
| DR-04 | Plan-to-feature inclusion is a many-to-many relationship carrying a quantity (Contact pack ×2 = 1,000), not a checkbox. |
| DR-05 | Entitlements are stored per customer per feature, with an aggregated quantity, an active window and a link back to the originating Opportunity for audit. |
| DR-06 | Entitlement records are durable and versioned (BR-28) — superseded, never silently overwritten. |
| DR-07 | Every record exposed to a downstream system carries a stable external code (BR-03) and, where relevant, an external Id field for upsert-based sync. |
| DR-08 | Recurring and one-time charges are explicitly distinguished on committed lines, because billing treats them differently and entitlements derive only from the recurring, feature-bearing ones (BR-29). |

---

## 11. Downstream Consumers

The model exists to serve two systems that are outside this project's build scope (X-4) but inside its design responsibility.

### 11.1 Feature-Gating Service

Answers, per customer: *is this capability on, and how much of it?*

**Needs from the model:** a stable feature code (never a Salesforce Id); a resolved quantity for metered features already aggregated across plan and add-ons — the gating service must never re-derive `500 + 500`; an active window so an expired contract stops granting access; and a single current row per customer per feature, so gating is a lookup rather than a computation.

### 11.2 Billing System

Answers: *what do we invoice, how much and how often?*

**Needs from the model:** each contracted line with its negotiated price, quantity and charge type (recurring monthly vs one-time); the contract effective date, term and end date; the setup fee as a distinct one-time line, not folded into the recurring amount; the account and Opportunity for reconciliation; and a stable external key so re-syncing does not double-bill.

### 11.3 Design Consequence

These two consumers want different slices of the same event. Billing wants the **commercial** lines including the non-entitling Design Refresh; gating wants the **capability** rows and must never see it. Modelling entitlements as a projection of the committed lines — rather than pointing both systems at `OpportunityLineItem` and letting each interpret it — is what keeps them from disagreeing (P-4). A future phase can push these out over Platform Events; the model is shaped so that becomes a publish, not a redesign.

---

## 12. Assumptions

| ID | Assumption |
|---|---|
| AS-1 | Add-on list prices, floors and charge types are placeholders pending RevOps confirmation (§7.3, OQ-2). |
| AS-2 | Plan prices are monthly recurring; setup fees are one-time. Billing frequency is monthly. |
| AS-3 | All amounts are USD; multi-currency is not in scope for this phase. |
| AS-4 | The Opportunity has an Account before commit — entitlements are held against a customer, and an Opportunity without one cannot produce them. |
| AS-5 | A standard price book is active and contains an entry for every sellable catalog item (DR-02). |
| AS-6 | Permitted contract terms are 12, 24 and 36 months (BR-17), configurable without code. |
| AS-7 | The React/NestJS platform is a trusted server-side caller holding its own credentials; end reps never hold Salesforce credentials. |
| AS-8 | One active subscription per Account per plan at a time. Concurrent overlapping subscriptions are a renewals/amendments concern (X-8). |
| AS-9 | The rep's identity is passed by the platform in the request (§5). Salesforce cannot otherwise attribute a discount to a person. |

---

## 13. Open Questions

| ID | Question | Owner | Impact if unresolved |
|---|---|---|---|
| OQ-1 | Is uplift above list price permitted, or should there be a ceiling as well as a floor (BR-11)? | Sales leadership | Currently unbounded. A ceiling is a one-line rule change if wanted. |
| OQ-2 | Confirm add-on list prices, floors and charge types (AS-1). | RevOps | Prototype ships with placeholders. Catalog data change only — no code impact. |
| OQ-3 | Should the setup fee be waivable to $0 by any rep (BR-12), or does a waiver need its own floor? | Sales leadership / Finance | Currently freely waivable. |
| OQ-4 | Should sub-floor attempts route to a manager, or remain a hard stop? | Sales leadership | The brief says hard stop (X-5). Recorded because it is the most likely first change request once reps hit the floor. |
| OQ-5 | What is the expected commit volume at peak, and the platform's latency budget? | RevTech engineering | Drives whether catalog reads need caching beyond the platform's own. |
| OQ-6 | When a contract term ends, who deactivates entitlements — a scheduled Salesforce job, or the gating service reading the end date? | RevTech engineering | Model supports both (active window on the entitlement); the operational owner is undecided. |

---

## 14. Acceptance Criteria

The conditions under which this phase is considered delivered.

| ID | Given | When | Then |
|---|---|---|---|
| AC-01 | A published catalog | The platform requests the catalog | Three plans with prices, floors, setup fees and included features, and three add-ons with prices and floors, are returned with stable codes. |
| AC-02 | Brand plan, floor $450 | A configuration is validated at **$450.00** | **Pass.** The floor is inclusive — exactly at floor is allowed. |
| AC-03 | Brand plan, floor $450 | A configuration is validated at **$449.99** | **Fail**, with a violation naming the plan, the submitted price and the floor. |
| AC-04 | A configuration with a sub-floor plan price *and* a sub-floor add-on price | It is validated | **Fail**, with **both** violations in one response (BR-15). |
| AC-05 | A valid configuration | It is committed to an existing Opportunity | Opportunity Products are created for the plan, the setup fee and each add-on at the confirmed prices and quantities; effective date and term are set on the Opportunity. |
| AC-06 | A sub-floor configuration | It is committed, skipping validate | **No records are created.** The commit is refused with the same structured violations (BR-19, BR-20). |
| AC-07 | An Opportunity with a previously committed configuration | A revised configuration is committed | The previous CPQ lines are replaced, not duplicated (BR-23). |
| AC-08 | The same commit request | It is submitted twice with the same idempotency key | One set of lines exists; the second call returns the original result (BR-24). |
| AC-09 | A committed Brand deal with Contacts (500) ×1 | The Opportunity moves to Closed Won | A subscription is created, and the Contacts entitlement reads **1,000** (§7.3). |
| AC-10 | 200 Opportunities with committed configurations | All are moved to Closed Won in one bulk update | All subscriptions and entitlements are created correctly, within governor limits (FR-21). |
| AC-11 | An already Closed Won Opportunity | It is edited and saved again | No duplicate subscription or entitlement is created (BR-27). |
| AC-12 | A committed All In deal | Closed Won fires | Competitor Analysis is entitled once, not twice, despite being both plan-included and added (§7.3). |
| AC-13 | A commit with a Design Refresh add-on | Closed Won fires | Design Refresh appears as a billable one-time line and produces **no** entitlement (BR-29). |
| AC-14 | A malformed request (bad Opportunity Id, unknown plan code, negative price) | It is submitted | A typed error with the correct HTTP status is returned; no unhandled exception, no partial write (NFR-08). |
| AC-15 | Any commit, validation failure or error | It occurs | A log record exists with correlation ID, rep, outcome and timestamp (FR-26). |
| AC-16 | The repository | It is deployed to a clean scratch org | All metadata deploys and all Apex tests pass (NFR-09, NFR-02). |

---

## 15. Traceability

Every capability the brief asks for, mapped to the requirements that carry it.

| Brief requirement | Business rules | Functional reqs | Acceptance |
|---|---|---|---|
| 1. Catalog access | BR-01 – BR-04 | FR-01 – FR-05 | AC-01 |
| 2. Server-side price floor enforcement | BR-05 – BR-18 | FR-06 – FR-11 | AC-02, AC-03, AC-04 |
| 3. Commit to Opportunity | BR-19 – BR-24 | FR-12 – FR-18 | AC-05 – AC-08, AC-14 |
| 4. Closed Won automation | BR-25 – BR-29 | FR-19 – FR-25 | AC-09 – AC-13 |
| 5. Logging & monitoring | — | FR-26 – FR-31 | AC-15 |
| Entitlement aggregation | BR-26 | FR-20 | AC-09, AC-12 |
| Downstream: feature gating | BR-03, BR-26 | §11.1 | AC-09, AC-12 |
| Downstream: billing | BR-29, DR-08 | §11.2 | AC-13 |
| Security on external surface | — | NFR-03, NFR-04 | *(design doc)* |
| Bulk safety & test coverage | — | NFR-01, NFR-02 | AC-10, AC-16 |

---

## 16. Glossary

| Term | Definition |
|---|---|
| **Add-on** | An optional product attached to a configuration beyond the plan. Three exist: Design Refresh, Competitor Analysis, Contacts (500). |
| **Binary feature** | A capability a customer either has or does not, with no quantity — e.g. website hosting. |
| **Charge type** | Whether a line bills recurring monthly or one-time. Drives both billing and entitlement derivation. |
| **Commit** | Writing a finalised configuration to an Opportunity as Opportunity Products. |
| **Configuration** | A proposed deal: one plan, a negotiated price, a setup fee, zero or more add-ons, and contract terms. |
| **Correlation ID** | A caller-supplied or system-generated identifier threading one logical request through logs for support. |
| **Entitlement** | A durable record of a capability a customer is owed, with quantity and active window. Consumed by feature gating. Distinct from Salesforce's standard Service Cloud `Entitlement` object, which is not used here. |
| **Feature** | A capability granted by a plan or an add-on — e.g. `FEAT_CONTACTS`. |
| **Floor** | The lowest price at which a plan or add-on may be sold. Enforced server-side. |
| **Headless** | Salesforce as API and business-logic layer, with the user interface built elsewhere. |
| **Idempotency key** | A caller-supplied token making a repeated commit safe to retry. |
| **Metered feature** | A capability carrying an accumulating quantity — e.g. contacts. |
| **Setup fee** | A one-time charge attached to a plan. Billable; grants no entitlement. |
| **Subscription** | The customer-level record of a won contract: account, plan, effective date, term. Parent of the entitlements. |

---

## Appendix A — Document History

| Version | Date | Author | Change |
|---|---|---|---|
| 1.0 | 7 Sep 2026 | Bruno Romano | Initial version for review. |

## Appendix B — References

- Luxury Presence, *Real Estate Marketing Platform* — https://www.luxurypresence.com/real-estate-marketing-platform/
- Luxury Presence, *About Us* — https://www.luxurypresence.com/about-us/
- Business Wire, *Luxury Presence Launches the New Presence® Platform* (6 May 2026)
- RevTech Senior Salesforce Developer — Case Study: Custom CPQ Solution Design (source brief)
