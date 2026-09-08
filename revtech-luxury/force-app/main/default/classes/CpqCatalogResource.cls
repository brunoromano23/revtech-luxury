/**
 * GET /services/apexrest/cpq/v1/catalog?effectiveDate=yyyy-mm-dd
 *
 * Everything the platform needs to render the configurator: plans with their floors, setup fees and
 * included features, and add-ons with their floors and mapped features. Read-only and cacheable.
 *
 * The floors travel with the payload so the client can show a rep where the limit is — but the
 * client showing it is a courtesy, not the enforcement. That happens in CpqValidator, server-side,
 * on every validate and again on every commit.
 */
@RestResource(urlMapping='/cpq/v1/catalog')
global with sharing class CpqCatalogResource {
    @HttpGet
    global static void getCatalog() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        String correlationId = CpqRestSupport.correlationId(request);
        Long startedAt = System.currentTimeMillis();

        try {
            Date effectiveDate = CpqRestSupport.parseEffectiveDate(request.params.get('effectiveDate'));
            CpqCatalog catalog = CpqCatalogService.load(effectiveDate);
            CpqDto.CatalogResponse body = CpqCatalogService.describe(catalog, correlationId);

            CpqRestSupport.respond(response, 200, body);
            CpqLogger.success(correlationId, 'GET /cpq/v1/catalog', null, null, System.currentTimeMillis() - startedAt);
        } catch (CpqException e) {
            CpqRestSupport.respondError(response, correlationId, e);
        } catch (Exception e) {
            CpqRestSupport.respondUnexpected(response, correlationId, 'GET /cpq/v1/catalog', e);
        }
    }
}
