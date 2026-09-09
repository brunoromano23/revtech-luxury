# Testing the REST surface from Postman

This is the closest thing to how the React/NestJS platform will actually call Salesforce: a
server-to-server token from the client credentials flow, then the three endpoints. Nothing here
uses a Salesforce UI session, so what you are testing is the integration principal's real
permissions — not your admin's.

Import [`RevTech-CPQ.postman_collection.json`](RevTech-CPQ.postman_collection.json).

---

## One-time setup

The integration user and the Connected App are both in the repo and deploy with everything else:

```bash
sf project deploy start -d force-app
sf apex run --file scripts/apex/create-integration-user.apex
```

Two things cannot be automated, because Salesforce exposes neither through the Metadata API.

**1 · Point the Connected App at the integration user.**
Setup → App Manager → **RevTech CPQ Platform** → dropdown → **Manage** → **Edit Policies** →
under *Client Credentials Flow*, set **Run As** to `svc.revtech.cpq@revtech.luxury.demo` → Save.

This is the whole security model in one field. The token the platform receives carries that user's
permissions, and nothing else.

**2 · Copy the credentials.**
Setup → App Manager → **RevTech CPQ Platform** → **View** → *Consumer Key and Secret* → Manage
Consumer Details. Copy both into the collection variables `clientId` and `clientSecret`.

> Connected App changes take a few minutes to propagate. A `400 invalid_client` immediately after
> saving usually means "wait", not "wrong secret".

---

## Running it

Set `loginUrl` to your My Domain URL if you are not on the `luxury` org. Then run the folders in
order — or use the Collection Runner, which does the same thing and gives you a pass/fail report.

| Folder | What it proves |
|---|---|
| **0 · Auth** | The Connected App issues a token for the integration user. Stores `accessToken` and `instanceUrl` for everything after it. |
| **1 · Catalog** | The integration user can read the catalog under user-mode enforcement, and the wire contract still has the field names the client binds to. |
| **2 · Validate** | The floor is inclusive, every violation comes back in one response, and malformed JSON returns a typed 400 with no Apex internals. |
| **3 · Commit** | A sub-floor commit that skipped `/validate` is refused with 422; a valid one writes four lines; the same idempotency key replays instead of double-writing. |
| **4 · Negative paths** | A malformed Id is a 400, an unknown Opportunity is a 404 rather than an Id oracle. |

**Before folder 3**, set `opportunityId` to an open Opportunity that has an Account. The quickest
source is the demo script, which prints one:

```bash
./scripts/demo.sh luxury --stage-live
```

---

## What this catches that the Apex tests cannot

The Apex tests build a `RestRequest` by hand and call the handler directly, so three things are
never exercised in CI and are exercised here:

- **`urlMapping` routing.** A typo in `@RestResource(urlMapping=...)` passes all 66 Apex tests and
  404s in production. Only a real HTTP call finds it.
- **Authentication.** No Apex test involves a Connected App, a token, or an OAuth flow.
- **The integration user's actual permissions.** The Apex tests run as whoever runs them — which,
  on this machine, is an admin holding both permission sets. Postman runs as
  `svc.revtech.cpq` holding only `CPQ_Integration_User`. A `403` here is a real permission gap
  that the test suite structurally cannot see.

That last one is the reason to keep this collection rather than treat it as a one-off.

---

## What running as the real principal actually found

Every one of these passed all 66 Apex tests and failed the first HTTP call. None is theoretical;
each was found by calling the API as `svc.revtech.cpq` and reading the error.

**1 · The Salesforce Integration license cannot host this API.**
The solution design specified one. Probing object by object, that licence refuses `Read` on
`Account`, `Opportunity` and `Product2`, and `Pricebook2` depends on `Product2`. Assigning
`CPQ_Integration_User` to such a user fails outright with `FIELD_INTEGRITY_EXCEPTION`. Since §4.3
makes `PricebookEntryId` mandatory on every line, the licence can never work here — so
`svc.revtech.cpq` runs on a **full Salesforce license** with `Minimum Access - Salesforce`. The
least-privilege argument survives; the "cheaper than a full seat" claim does not.

**2 · `ApiEnabled` and `ApexRestServices` were missing.**
Authentication succeeded and every endpoint returned `403 APEX_REST_SERVICES_DISABLED`. Neither
permission is implied by object access, and no `RestContext` test can miss them — the check happens
at the HTTP boundary those tests never cross.

**3 · The permission set granted FLS only on its own custom fields.**
Standard fields the services read — `Opportunity.AccountId` above all — had no field permissions.
SOQL reports this as `No such column 'AccountId' on entity 'Opportunity'`, which reads like a typo
and is actually a permission. Note `Account` object read is required too: a lookup to an object the
running user cannot read does not exist as far as SOQL is concerned. Fields that are not
FLS-controlled at all (`StageName`, `IsClosed`, `Quantity`, `UnitPrice`, `PricebookEntryId`) follow
object access and are deliberately absent from the permission set.

**4 · `EditOppLineItemUnitPrice` — the one that matters most.**
Without it, inserting a line below its `PricebookEntry` list price fails with *"User may not specify
unit price different from list price"*. A CPQ built entirely around negotiated pricing under a floor
cannot write a single discounted line without this permission. It is the least obvious requirement
in the system and the one that most completely breaks it.

**Still open:** a commit that returns `500` writes no log row. Successes and validation failures log
correctly, so the publish path works — the internal-error path does not reach it. Worth fixing
alongside the logging work.
