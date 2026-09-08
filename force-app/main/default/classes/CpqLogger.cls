/**
 * Logging for the CPQ surface.
 *
 * Logs are published as platform events rather than inserted directly. A commit that fails rolls
 * back to its savepoint, and a log row inserted inside that transaction would roll back with it —
 * so the failures most worth seeing are exactly the ones that would erase themselves.
 * CPQ_Log_Event__e is configured PublishImmediately, which commits independently of the enclosing
 * transaction (solution design 7.2). CpqLogEventTrigger writes the durable row.
 */
public with sharing class CpqLogger {
    @TestVisible
    private static List<CPQ_Log_Event__e> published = new List<CPQ_Log_Event__e>();

    public static void success(String correlationId, String endpoint, String rep, Id oppId, Long durationMs) {
        publish(build(correlationId, endpoint, rep, oppId, CpqConstants.OUTCOME_SUCCESS, null, durationMs, null, null));
    }

    /**
     * Sub-floor attempts are logged with their violation codes deliberately: how far below floor
     * reps are trying to go is the input to the next pricing conversation, not noise (design doc 7.2).
     */
    public static void validationFailed(
        String correlationId,
        String endpoint,
        String rep,
        Id oppId,
        List<CpqDto.Violation> violations,
        Long durationMs
    ) {
        List<String> codes = new List<String>();
        for (CpqDto.Violation v : violations) {
            codes.add(v.code);
        }
        publish(
            build(
                correlationId,
                endpoint,
                rep,
                oppId,
                CpqConstants.OUTCOME_VALIDATION_FAILED,
                codes,
                durationMs,
                null,
                null
            )
        );
    }

    public static void rejected(String correlationId, String endpoint, String rep, Id oppId, String message) {
        publish(
            build(correlationId, endpoint, rep, oppId, CpqConstants.OUTCOME_REJECTED, null, null, message, null)
        );
    }

    public static void error(String correlationId, String endpoint, String rep, Id oppId, Exception e) {
        publish(
            build(
                correlationId,
                endpoint,
                rep,
                oppId,
                CpqConstants.OUTCOME_ERROR,
                null,
                null,
                e.getMessage(),
                e.getStackTraceString()
            )
        );
    }

    private static CPQ_Log_Event__e build(
        String correlationId,
        String endpoint,
        String rep,
        Id oppId,
        String outcome,
        List<String> violationCodes,
        Long durationMs,
        String message,
        String stackTrace
    ) {
        return new CPQ_Log_Event__e(
            Correlation_Id__c = correlationId,
            Endpoint__c = endpoint,
            Acting_Rep__c = rep,
            Integration_User__c = UserInfo.getUserName(),
            Opportunity_Id__c = oppId == null ? null : String.valueOf(oppId),
            Outcome__c = outcome,
            Violation_Codes__c = violationCodes == null ? null : truncate(String.join(violationCodes, ','), 255),
            Duration_Ms__c = durationMs == null ? null : Decimal.valueOf(durationMs),
            Message__c = truncate(message, 32768),
            Stack_Trace__c = truncate(stackTrace, 32768)
        );
    }

    private static void publish(CPQ_Log_Event__e event) {
        published.add(event);
        // Never let logging be the reason a request fails. A dropped log is a monitoring gap;
        // a thrown logger turns a successful commit into a 500.
        try {
            EventBus.publish(event);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'CPQ log publish failed: ' + e.getMessage());
        }
    }

    private static String truncate(String value, Integer max) {
        if (String.isBlank(value)) {
            return value;
        }
        return value.length() <= max ? value : value.substring(0, max);
    }
}
