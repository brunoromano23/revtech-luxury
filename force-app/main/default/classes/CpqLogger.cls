/**
 * Logging for the CPQ surface, over Nebula Logger.
 *
 * The architectural requirement has not changed: a commit that fails rolls back to its savepoint,
 * and a log row inserted inside that transaction rolls back with it — so the failures most worth
 * seeing are exactly the ones that erase themselves. Nebula satisfies this natively. Its default
 * save method is EVENT_BUS and LogEntryEvent__e publishes immediately, which commits independently
 * of the enclosing transaction. Verified directly against this org: a log written inside a
 * transaction that was then rolled back is still present afterwards.
 *
 * What Nebula replaced: CPQ_Integration_Log__c, CPQ_Log_Event__e and CpqLogEventTrigger. What it
 * could not supply is the correlation ID shared with the React/NestJS platform — Nebula's
 * TransactionId__c identifies a Salesforce transaction, not the caller's request — so that is the
 * one custom field added to its objects.
 *
 * This class stays a thin adapter with the same public surface it had before, so no caller changed
 * when the implementation did. That is the whole argument for having had it in the first place.
 */
public with sharing class CpqLogger {
    /** Tag namespace, so CPQ entries are separable from anything else logging in the org. */
    private static final String TAG_CPQ = 'cpq';

    /**
     * What this class built, for the tests to assert against.
     *
     * The tests deliberately verify the event we produce rather than the LogEntry__c row Nebula
     * derives from it. Persisting the event is Nebula's responsibility and is covered by Nebula's
     * own suite; in an Apex test its handler does not run, so asserting on the row would test the
     * framework's test harness rather than this adapter. That the row genuinely survives a
     * rolled-back transaction was verified directly against the org instead — see the class comment.
     */
    @TestVisible
    private static List<LogEntryEvent__e> published = new List<LogEntryEvent__e>();

    public static void success(String correlationId, String endpoint, String rep, Id oppId, Long durationMs) {
        entry(LoggingLevel.INFO, correlationId, endpoint, rep, oppId, CpqConstants.OUTCOME_SUCCESS, null, durationMs, null)
            ?.addTag(CpqConstants.OUTCOME_SUCCESS);
        save();
    }

    /**
     * Sub-floor attempts are logged with their violation codes deliberately: how far below floor
     * reps are trying to go is the input to the next pricing conversation, not noise. The codes are
     * tags rather than a delimited string, so "how often did ADDON_BELOW_FLOOR fire this quarter"
     * is a report rather than a text search.
     */
    public static void validationFailed(
        String correlationId,
        String endpoint,
        String rep,
        Id oppId,
        List<CpqDto.Violation> violations,
        Long durationMs
    ) {
        List<String> codes = new List<String>{ TAG_CPQ, CpqConstants.OUTCOME_VALIDATION_FAILED };
        for (CpqDto.Violation v : violations) {
            codes.add(v.code);
        }
        LogEntryEventBuilder builder = entry(
            LoggingLevel.WARN,
            correlationId,
            endpoint,
            rep,
            oppId,
            CpqConstants.OUTCOME_VALIDATION_FAILED,
            violations,
            durationMs,
            null
        );
        if (builder != null) {
            builder.addTags(codes);
        }
        save();
    }

    public static void rejected(String correlationId, String endpoint, String rep, Id oppId, String message) {
        entry(LoggingLevel.WARN, correlationId, endpoint, rep, oppId, CpqConstants.OUTCOME_REJECTED, null, null, message)
            ?.addTag(CpqConstants.OUTCOME_REJECTED);
        save();
    }

    public static void error(String correlationId, String endpoint, String rep, Id oppId, Exception e) {
        LogEntryEventBuilder builder = entry(
            LoggingLevel.ERROR,
            correlationId,
            endpoint,
            rep,
            oppId,
            CpqConstants.OUTCOME_ERROR,
            null,
            null,
            e == null ? null : e.getMessage()
        );
        if (builder != null) {
            builder.addTag(CpqConstants.OUTCOME_ERROR);
            if (e != null) {
                // Nebula captures type, message, stack trace and line number from the exception
                // itself, so the caller keeps getting a correlation ID and nothing more.
                builder.setExceptionDetails(e);
            }
        }
        save();
    }

    private static LogEntryEventBuilder entry(
        LoggingLevel level,
        String correlationId,
        String endpoint,
        String rep,
        Id oppId,
        String outcome,
        List<CpqDto.Violation> violations,
        Long durationMs,
        String message
    ) {
        try {
            // Scenario groups a transaction by the endpoint that drove it, which is what the
            // operational dashboards slice on.
            if (String.isNotBlank(endpoint)) {
                Logger.setScenario(endpoint);
            }

            String text = outcome + (String.isBlank(endpoint) ? '' : ' ' + endpoint);
            if (String.isNotBlank(message)) {
                text += ' — ' + message;
            }
            if (durationMs != null) {
                text += ' (' + durationMs + 'ms)';
            }
            if (String.isNotBlank(rep)) {
                text += ' [rep ' + rep + ']';
            }

            LogEntryEventBuilder builder = Logger.newEntry(level, text);
            builder.addTag(TAG_CPQ);
            if (oppId != null) {
                builder.setRecord(oppId);
            }
            if (String.isNotBlank(correlationId)) {
                builder.getLogEntryEvent().Correlation_Id__c = correlationId.left(64);
            }
            published.add(builder.getLogEntryEvent());
            return builder;
        } catch (Exception loggingFailure) {
            // Never let logging be the reason a request fails. A dropped log is a monitoring gap;
            // a thrown logger turns a successful commit into a 500.
            System.debug(LoggingLevel.ERROR, 'CPQ logging failed: ' + loggingFailure.getMessage());
            return null;
        }
    }

    private static void save() {
        try {
            Logger.saveLog();
        } catch (Exception loggingFailure) {
            System.debug(LoggingLevel.ERROR, 'CPQ log save failed: ' + loggingFailure.getMessage());
        }
    }
}
