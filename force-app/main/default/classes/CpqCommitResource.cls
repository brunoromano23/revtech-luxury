/**
 * POST /services/apexrest/cpq/v1/opportunities/{opportunityId}/commit
 *
 * Writes a finalised configuration to an Opportunity that already exists. Re-validates from scratch
 * before writing anything (R-13), writes atomically (R-14), and is idempotent by key (R-17).
 *
 * The wildcard sits mid-path, which Apex REST allows as long as it is delimited by slashes.
 */
@RestResource(urlMapping='/cpq/v1/opportunities/*/commit')
global with sharing class CpqCommitResource {
    @HttpPost
    global static void commitConfiguration() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        String correlationId = CpqRestSupport.correlationId(request);
        Long startedAt = System.currentTimeMillis();
        final String endpoint = 'POST /cpq/v1/opportunities/{id}/commit';

        Id opportunityId;
        String actingRep;
        try {
            opportunityId = CpqRestSupport.opportunityIdFromUri(request.requestURI);
            CpqDto.ConfigurationRequest configuration = CpqRestSupport.parseConfiguration(request, correlationId);
            actingRep = configuration.actingRepEmail;

            if (String.isBlank(configuration.idempotencyKey)) {
                throw CpqException.badRequest(
                    'IDEMPOTENCY_KEY_REQUIRED',
                    'idempotencyKey is required so a retried commit cannot double-write.'
                );
            }

            CpqCommitService.Outcome outcome = CpqCommitService.commitConfiguration(opportunityId, configuration);
            Long elapsed = System.currentTimeMillis() - startedAt;

            if (outcome.refused) {
                CpqRestSupport.respondRefused(response, correlationId, outcome.validation.violations);
                CpqLogger.validationFailed(
                    correlationId,
                    endpoint,
                    actingRep,
                    opportunityId,
                    outcome.validation.violations,
                    elapsed
                );
                return;
            }

            CpqRestSupport.respond(response, 200, outcome.response);
            CpqLogger.success(correlationId, endpoint, actingRep, opportunityId, elapsed);
        } catch (CpqException e) {
            CpqRestSupport.respondError(response, correlationId, e);
            CpqLogger.rejected(correlationId, endpoint, actingRep, opportunityId, e.errorCode + ': ' + e.getMessage());
        } catch (Exception e) {
            CpqRestSupport.respondUnexpected(response, correlationId, endpoint, e);
        }
    }
}
