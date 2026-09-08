/**
 * Shared plumbing for the three endpoints: correlation IDs, JSON in, JSON out, and a single place
 * where an exception becomes a status code.
 *
 * Nulls are serialised rather than suppressed. A field that is always present and sometimes null is
 * easier for the platform to code against than one that vanishes, and it keeps the response shape
 * stable across versions.
 */
public with sharing class CpqRestSupport {
    public static final String HEADER_CORRELATION = 'X-Correlation-Id';

    /** The caller's correlation ID if it sent one, so one ID spans their logs and ours. */
    public static String correlationId(RestRequest request) {
        String supplied = request == null || request.headers == null ? null : request.headers.get(HEADER_CORRELATION);
        return String.isNotBlank(supplied) ? supplied.left(64) : newCorrelationId();
    }

    public static String newCorrelationId() {
        // UUID-shaped and unique enough to join two systems' logs; not a security token.
        Blob random = Crypto.generateAesKey(128);
        String hex = EncodingUtil.convertToHex(random);
        return hex.substring(0, 8) +
            '-' +
            hex.substring(8, 12) +
            '-' +
            hex.substring(12, 16) +
            '-' +
            hex.substring(16, 20) +
            '-' +
            hex.substring(20, 32);
    }

    public static CpqDto.ConfigurationRequest parseConfiguration(RestRequest request, String correlationId) {
        if (request == null || request.requestBody == null || request.requestBody.size() == 0) {
            throw CpqException.badRequest('EMPTY_BODY', 'A request body is required.');
        }
        CpqDto.ConfigurationRequest parsed;
        try {
            parsed = (CpqDto.ConfigurationRequest) JSON.deserialize(
                request.requestBody.toString(),
                CpqDto.ConfigurationRequest.class
            );
        } catch (Exception e) {
            // Malformed JSON, an unexpected attribute, or a field of the wrong type. All of them
            // are the caller's problem to fix, so all of them are a 400 with the reason attached.
            throw CpqException.badRequest('MALFORMED_BODY', 'Request body could not be parsed: ' + e.getMessage());
        }
        if (parsed == null) {
            throw CpqException.badRequest('MALFORMED_BODY', 'Request body could not be parsed.');
        }
        if (String.isBlank(parsed.correlationId)) {
            parsed.correlationId = correlationId;
        }
        return parsed;
    }

    /** Parses a path segment as an Opportunity Id. A malformed Id is a clean 400 (design doc 7.1). */
    public static Id opportunityIdFromUri(String requestUri) {
        String raw;
        if (String.isNotBlank(requestUri)) {
            List<String> segments = requestUri.split('/');
            for (Integer i = 0; i < segments.size() - 1; i++) {
                if (segments[i] == 'opportunities') {
                    raw = segments[i + 1];
                    break;
                }
            }
        }
        if (String.isBlank(raw)) {
            throw CpqException.badRequest('MISSING_OPPORTUNITY_ID', 'The URL must contain an Opportunity Id.');
        }
        Id parsed;
        try {
            parsed = Id.valueOf(raw);
        } catch (Exception e) {
            throw CpqException.badRequest('INVALID_OPPORTUNITY_ID', raw + ' is not a valid Salesforce Id.');
        }
        if (parsed.getSobjectType() != Opportunity.SObjectType) {
            throw CpqException.badRequest('INVALID_OPPORTUNITY_ID', raw + ' is not an Opportunity Id.');
        }
        return parsed;
    }

    public static Date parseEffectiveDate(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            return Date.valueOf(raw);
        } catch (Exception e) {
            throw CpqException.badRequest('INVALID_EFFECTIVE_DATE', 'effectiveDate must be an ISO date (yyyy-mm-dd).');
        }
    }

    public static void respond(RestResponse response, Integer status, Object body) {
        response.statusCode = status;
        response.addHeader('Content-Type', 'application/json; charset=UTF-8');
        response.responseBody = Blob.valueOf(JSON.serialize(body));
    }

    public static void respondError(RestResponse response, String correlationId, CpqException e) {
        CpqDto.ErrorResponse error = new CpqDto.ErrorResponse(correlationId, e.errorCode, e.getMessage());
        respond(response, e.statusCode, error);
    }

    /** 422: the request was understood and refused on business rules (design doc 6.3). */
    public static void respondRefused(RestResponse response, String correlationId, List<CpqDto.Violation> violations) {
        CpqDto.ErrorResponse error = new CpqDto.ErrorResponse(
            correlationId,
            'CONFIGURATION_INVALID',
            'The configuration violates one or more commercial rules and was not committed.'
        );
        error.violations = violations;
        respond(response, 422, error);
    }

    /**
     * The last line of defence. The caller gets a correlation ID and nothing else; the stack trace
     * goes to the log, where it is useful and not exploitable.
     */
    public static void respondUnexpected(RestResponse response, String correlationId, String endpoint, Exception e) {
        CpqLogger.error(correlationId, endpoint, null, null, e);
        respond(
            response,
            500,
            new CpqDto.ErrorResponse(
                correlationId,
                'INTERNAL_ERROR',
                'An unexpected error occurred. Quote correlation ID ' + correlationId + ' to support.'
            )
        );
    }
}
