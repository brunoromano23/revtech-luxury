/**
 * A failure the caller can act on, carrying the HTTP status and the stable error code that go
 * back over the wire. Anything that escapes as a plain Apex exception is a bug: the REST layer
 * turns those into a 500 with a correlation ID and keeps the stack trace in the log (design doc 7.1).
 */
public virtual class CpqException extends Exception {
    public String errorCode;
    public Integer statusCode;

    public static CpqException badRequest(String code, String message) {
        return build(code, message, 400);
    }

    /**
     * Also the answer for "exists but you cannot see it". Distinguishing the two would let a caller
     * with valid credentials enumerate Opportunity Ids by reading the difference (design doc 7.1).
     */
    public static CpqException notFound(String message) {
        return build('NOT_FOUND', message, 404);
    }

    public static CpqException conflict(String code, String message) {
        return build(code, message, 409);
    }

    public static CpqException misconfigured(String message) {
        return build('CATALOG_MISCONFIGURED', message, 500);
    }

    private static CpqException build(String code, String message, Integer status) {
        CpqException e = new CpqException(message);
        e.errorCode = code;
        e.statusCode = status;
        return e;
    }
}
