/**
 * POST /services/apexrest/cpq/v1/configurations/validate
 *
 * Asks "is this configuration sellable?" and answers with a structured verdict. No DML, no side
 * effects, safe to call on every keystroke while a rep drags a price slider.
 *
 * A refused configuration is still a 200: the question was answered successfully, and the answer
 * was no. Commit is the endpoint that returns 422, because there the caller asked us to *write*
 * something and we declined (solution design 6.3).
 */
@RestResource(urlMapping='/cpq/v1/configurations/validate')
global with sharing class CpqValidateResource {
    @HttpPost
    global static void validate() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        String correlationId = CpqRestSupport.correlationId(request);
        Long startedAt = System.currentTimeMillis();
        final String endpoint = 'POST /cpq/v1/configurations/validate';

        try {
            CpqDto.ConfigurationRequest configuration = CpqRestSupport.parseConfiguration(request, correlationId);

            CpqCatalog catalog = CpqCatalogService.load(configuration.contractEffectiveDate);
            CpqValidator.Resolved resolved = CpqValidator.validate(configuration, catalog);

            CpqRestSupport.respond(response, 200, resolved.response);

            Long elapsed = System.currentTimeMillis() - startedAt;
            if (resolved.isValid()) {
                CpqLogger.success(correlationId, endpoint, configuration.actingRepEmail, null, elapsed);
            } else {
                CpqLogger.validationFailed(
                    correlationId,
                    endpoint,
                    configuration.actingRepEmail,
                    null,
                    resolved.response.violations,
                    elapsed
                );
            }
        } catch (CpqException e) {
            CpqRestSupport.respondError(response, correlationId, e);
        } catch (Exception e) {
            CpqRestSupport.respondUnexpected(response, correlationId, endpoint, e);
        }
    }
}
