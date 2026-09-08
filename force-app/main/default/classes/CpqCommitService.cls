/**
 * Writes a finalised configuration to an existing Opportunity as Opportunity Products.
 *
 * The whole write happens inside one savepoint (R-14): either the plan line, the setup-fee line,
 * every add-on line and the Opportunity's contract fields land, or nothing does. There is no state
 * in which a deal carries half a configuration.
 */
public with sharing class CpqCommitService {
    /** What the REST layer needs to choose a status code and a body. */
    public class Outcome {
        public CpqDto.CommitResponse response;
        public CpqDto.ValidationResponse validation;
        public Boolean refused = false;
    }

    public static Outcome commitConfiguration(Id opportunityId, CpqDto.ConfigurationRequest request) {
        Outcome outcome = new Outcome();

        Opportunity opp = loadOpportunity(opportunityId);

        // R-15. A closed deal is immutable to this API: its line items are what billing invoiced
        // and what the entitlements were built from.
        if (opp.IsClosed) {
            throw CpqException.conflict(
                'OPPORTUNITY_CLOSED',
                'Opportunity ' + opportunityId + ' is already closed and cannot be re-configured.'
            );
        }
        if (opp.AccountId == null) {
            throw CpqException.conflict(
                'OPPORTUNITY_HAS_NO_ACCOUNT',
                'Opportunity ' + opportunityId + ' has no Account, so it cannot produce entitlements.'
            );
        }

        String fingerprint = fingerprint(request);

        // R-17. Replay before doing any work, so a retried request is cheap as well as safe.
        CpqDto.CommitResponse replayed = replayIfSeen(request.idempotencyKey, fingerprint);
        if (replayed != null) {
            outcome.response = replayed;
            return outcome;
        }

        // R-13. Re-validate from scratch. A prior successful /validate call proves nothing: it may
        // be stale, it may have been against a different catalog, it may never have happened.
        CpqCatalog catalog = CpqCatalogService.load(request.contractEffectiveDate);
        CpqValidator.Resolved resolved = CpqValidator.validate(request, catalog);
        if (!resolved.isValid()) {
            outcome.refused = true;
            outcome.validation = resolved.response;
            return outcome;
        }

        outcome.response = write(opp, request, resolved, fingerprint);
        return outcome;
    }

    // =====================================================================
    // The transactional write
    // =====================================================================

    private static CpqDto.CommitResponse write(
        Opportunity opp,
        CpqDto.ConfigurationRequest request,
        CpqValidator.Resolved resolved,
        String fingerprint
    ) {
        Savepoint sp = Database.setSavepoint();
        try {
            CPQ_Commit__c commitRecord = new CPQ_Commit__c(
                Idempotency_Key__c = request.idempotencyKey,
                Correlation_Id__c = request.correlationId,
                Opportunity__c = opp.Id,
                Acting_Rep__c = resolveActingRep(request.actingRepEmail),
                Request_Hash__c = fingerprint,
                Status__c = 'Committed'
            );
            insertCommit(commitRecord, request.idempotencyKey, fingerprint);

            // R-16. Remove only what a previous commit of this API wrote. Lines a human or another
            // process added to the Opportunity are none of our business and survive untouched.
            List<OpportunityLineItem> priorLines = [
                SELECT Id
                FROM OpportunityLineItem
                WHERE OpportunityId = :opp.Id AND CPQ_Commit__c != NULL
                WITH USER_MODE
            ];
            if (!priorLines.isEmpty()) {
                Database.delete(priorLines, AccessLevel.USER_MODE);
            }

            Id pricebookId = opp.Pricebook2Id == null ? standardPricebookId() : opp.Pricebook2Id;
            Map<Id, Id> entryByProduct = pricebookEntries(pricebookId, resolved);

            List<OpportunityLineItem> lines = new List<OpportunityLineItem>();
            for (CpqValidator.ResolvedLine line : resolved.lines) {
                lines.add(
                    new OpportunityLineItem(
                        OpportunityId = opp.Id,
                        PricebookEntryId = entryByProduct.get(line.item.Product__c),
                        Quantity = line.quantity,
                        UnitPrice = line.unitPrice,
                        CPQ_Catalog_Item__c = line.item.Id,
                        CPQ_Charge_Type__c = line.item.Charge_Type__c,
                        CPQ_Commit__c = commitRecord.Id
                    )
                );
            }
            Database.insert(lines, AccessLevel.USER_MODE);

            // A narrow update carrying only what changes. Updating the queried record instead would
            // send read-only fields such as IsClosed back with it, which user-mode DML rejects.
            Database.update(
                new Opportunity(
                    Id = opp.Id,
                    Pricebook2Id = pricebookId,
                    Contract_Effective_Date__c = request.contractEffectiveDate,
                    Contract_Term_Months__c = request.contractTermMonths
                ),
                AccessLevel.USER_MODE
            );

            CpqDto.CommitResponse response = new CpqDto.CommitResponse();
            response.correlationId = request.correlationId;
            response.opportunityId = opp.Id;
            response.commitId = commitRecord.Id;
            response.lineItemIds = new List<String>();
            for (OpportunityLineItem line : lines) {
                response.lineItemIds.add(line.Id);
            }
            response.totals = CpqValidator.totals(resolved, request.contractTermMonths);
            response.contractEffectiveDate = request.contractEffectiveDate;
            response.contractTermMonths = request.contractTermMonths;
            response.replayed = false;

            // Snapshot the response so a later replay returns byte-for-byte what the caller
            // already acted on, rather than a freshly recomputed answer that may have drifted.
            List<CPQ_Commit__c> commitUpdates = new List<CPQ_Commit__c>{
                new CPQ_Commit__c(Id = commitRecord.Id, Response_Snapshot__c = JSON.serialize(response, true))
            };
            for (CPQ_Commit__c prior : [
                SELECT Id
                FROM CPQ_Commit__c
                WHERE Opportunity__c = :opp.Id AND Id != :commitRecord.Id AND Status__c = 'Committed'
                WITH USER_MODE
            ]) {
                commitUpdates.add(new CPQ_Commit__c(Id = prior.Id, Status__c = 'Superseded'));
            }
            Database.update(commitUpdates, AccessLevel.USER_MODE);

            return response;
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
    }

    // =====================================================================
    // Idempotency
    // =====================================================================

    private static CpqDto.CommitResponse replayIfSeen(String idempotencyKey, String fingerprint) {
        if (String.isBlank(idempotencyKey)) {
            return null;
        }
        List<CPQ_Commit__c> existing = [
            SELECT Id, Request_Hash__c, Response_Snapshot__c
            FROM CPQ_Commit__c
            WHERE Idempotency_Key__c = :idempotencyKey
            WITH USER_MODE
            LIMIT 1
        ];
        if (existing.isEmpty()) {
            return null;
        }
        return replayOf(existing[0], idempotencyKey, fingerprint);
    }

    private static CpqDto.CommitResponse replayOf(CPQ_Commit__c existing, String idempotencyKey, String fingerprint) {
        // Same key, different configuration. Replaying would return a result for a payload the
        // caller did not send; committing would silently overwrite. Neither is safe, so: conflict.
        if (existing.Request_Hash__c != fingerprint) {
            throw CpqException.conflict(
                'IDEMPOTENCY_KEY_REUSED',
                'Idempotency key ' + idempotencyKey + ' was already used for a different configuration.'
            );
        }
        if (String.isBlank(existing.Response_Snapshot__c)) {
            throw CpqException.conflict(
                'COMMIT_IN_PROGRESS',
                'A commit for idempotency key ' + idempotencyKey + ' is already in flight.'
            );
        }
        CpqDto.CommitResponse response = (CpqDto.CommitResponse) JSON.deserialize(
            existing.Response_Snapshot__c,
            CpqDto.CommitResponse.class
        );
        response.replayed = true;
        return response;
    }

    /**
     * The unique External Id on Idempotency_Key__c is what makes R-17 real. Querying first and then
     * inserting passes every test you can write and still loses a race in production, so the
     * duplicate-value error from the database is treated as the authoritative answer.
     */
    private static void insertCommit(CPQ_Commit__c record, String idempotencyKey, String fingerprint) {
        try {
            Database.insert(record, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            if (e.getDmlType(0) == StatusCode.DUPLICATE_VALUE) {
                CpqDto.CommitResponse replayed = replayIfSeen(idempotencyKey, fingerprint);
                if (replayed != null) {
                    throw CpqException.conflict(
                        'COMMIT_IN_PROGRESS',
                        'A concurrent commit for idempotency key ' + idempotencyKey + ' won the race.'
                    );
                }
            }
            throw e;
        }
    }

    /**
     * A stable fingerprint of what is being sold, excluding the fields that legitimately differ
     * between a request and its retry (correlation id, acting rep).
     */
    @TestVisible
    private static String fingerprint(CpqDto.ConfigurationRequest request) {
        List<String> parts = new List<String>{
            String.valueOf(request.planCode),
            String.valueOf(request.planPrice),
            String.valueOf(request.setupFee),
            String.valueOf(request.contractEffectiveDate),
            String.valueOf(request.contractTermMonths)
        };
        List<String> addOns = new List<String>();
        if (request.addOns != null) {
            for (CpqDto.AddOnLine line : request.addOns) {
                if (line != null) {
                    addOns.add(line.code + ':' + line.quantity + ':' + line.unitPrice);
                }
            }
        }
        addOns.sort();
        parts.addAll(addOns);
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(parts, '|')));
        return EncodingUtil.convertToHex(digest);
    }

    // =====================================================================
    // Lookups
    // =====================================================================

    private static Opportunity loadOpportunity(Id opportunityId) {
        List<Opportunity> found = [
            SELECT Id, AccountId, IsClosed, StageName, Pricebook2Id
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        if (found.isEmpty()) {
            // Not found and not permitted deliberately look identical (design doc 7.1).
            throw CpqException.notFound('Opportunity ' + opportunityId + ' was not found.');
        }
        return found[0];
    }

    private static Map<Id, Id> pricebookEntries(Id pricebookId, CpqValidator.Resolved resolved) {
        Set<Id> productIds = new Set<Id>();
        for (CpqValidator.ResolvedLine line : resolved.lines) {
            if (line.item.Product__c == null) {
                throw CpqException.misconfigured(
                    'Catalog item ' + line.item.Code__c + ' has no Product, so it cannot be sold.'
                );
            }
            productIds.add(line.item.Product__c);
        }

        Map<Id, Id> entryByProduct = new Map<Id, Id>();
        for (PricebookEntry entry : [
            SELECT Id, Product2Id
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId AND Product2Id IN :productIds AND IsActive = TRUE
            WITH USER_MODE
        ]) {
            entryByProduct.put(entry.Product2Id, entry.Id);
        }

        for (CpqValidator.ResolvedLine line : resolved.lines) {
            if (!entryByProduct.containsKey(line.item.Product__c)) {
                throw CpqException.misconfigured(
                    'Catalog item ' + line.item.Code__c + ' has no active price book entry in the active price book.'
                );
            }
        }
        return entryByProduct;
    }

    private static Id resolveActingRep(String email) {
        if (String.isBlank(email)) {
            return null;
        }
        List<User> users = [SELECT Id FROM User WHERE Username = :email AND IsActive = TRUE WITH USER_MODE LIMIT 1];
        if (users.isEmpty()) {
            users = [SELECT Id FROM User WHERE Email = :email AND IsActive = TRUE WITH USER_MODE LIMIT 1];
        }
        if (users.isEmpty()) {
            // Attribution is required, not optional: an unattributable discount defeats the point
            // of enforcing a floor at all (design doc 6.4).
            throw CpqException.badRequest(
                'UNKNOWN_ACTING_REP',
                'actingRepEmail ' + email + ' does not resolve to an active Salesforce user.'
            );
        }
        return users[0].Id;
    }

    private static Id standardPricebookId() {
        if (Test.isRunningTest()) {
            return Test.getStandardPricebookId();
        }
        List<Pricebook2> standard = [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1];
        if (standard.isEmpty()) {
            throw CpqException.misconfigured('No standard price book is available in this org.');
        }
        return standard[0].Id;
    }
}
