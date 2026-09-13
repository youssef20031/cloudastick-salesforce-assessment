/**
 * The single writer of every ABC REST response.
 *
 * Success or failure, the Ionic app always receives the same envelope:
 *
 *   { "success": true|false,
 *     "data": { ... } | null,
 *     "errors": [ { "code": "...", "message": "...", "field": "..."? } ],
 *     "requestId": "..." }
 *
 * so the client can parse one shape and never has to branch on status code to
 * find out where the payload is. requestId is the platform request id that
 * abc_Logger stamps on every log entry of the same transaction, which is what
 * turns a support ticket into a query on abc_Log__c.
 *
 * The body is written with JSONGenerator rather than JSON.serialize because the
 * envelope must keep "data": null and an empty "errors": [] rather than drop
 * them - a client should never have to distinguish absent from null.
 */
public with sharing class abc_RestResponse {
    private static final String CONTENT_TYPE_JSON = 'application/json';

    /** One entry of the envelope's errors array. */
    public class ApiError {
        public String code;
        public String message;
        public String fieldName;

        public ApiError(String code, String message, String fieldName) {
            this.code = code;
            this.message = message;
            this.fieldName = fieldName;
        }
    }

    private abc_RestResponse() {
        // Static utility - never instantiated.
    }

    // ------------------------------------------------------------- success

    /** 200 with a payload. */
    public static void ok(Object data) {
        sendSuccess(200, data);
    }

    /** 201, used when a cart has just been created. */
    public static void created(Object data) {
        sendSuccess(201, data);
    }

    public static void sendSuccess(Integer statusCode, Object data) {
        write(statusCode, buildSuccessBody(data));
    }

    // --------------------------------------------------------------- errors

    /** Sends the failure exactly as the thrower classified it. */
    public static void fail(abc_ApiException ex) {
        Integer status = ex.httpStatus == null ? abc_ApiException.statusFor(ex.errorCode) : ex.httpStatus;
        fail(status, ex.errorCode, ex.getMessage(), ex.errorField);
    }

    public static void fail(Integer statusCode, String code, String message, String fieldName) {
        write(statusCode, buildErrorBody(new List<ApiError>{ new ApiError(code, message, fieldName) }));
    }

    // ------------------------------------------------------------ rendering

    public static String buildSuccessBody(Object data) {
        return buildBody(true, data, new List<ApiError>());
    }

    public static String buildErrorBody(List<ApiError> errors) {
        return buildBody(false, null, errors);
    }

    public static String buildBody(Boolean success, Object data, List<ApiError> errors) {
        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeBooleanField('success', success == true);

        if (data == null) {
            gen.writeNullField('data');
        } else {
            gen.writeObjectField('data', data);
        }

        gen.writeFieldName('errors');
        gen.writeStartArray();
        if (errors != null) {
            for (ApiError err : errors) {
                gen.writeStartObject();
                gen.writeStringField('code', err.code == null ? abc_ApiException.CODE_INTERNAL_ERROR : err.code);
                gen.writeStringField('message', err.message == null ? '' : err.message);
                if (String.isNotBlank(err.fieldName)) {
                    gen.writeStringField('field', err.fieldName);
                }
                gen.writeEndObject();
            }
        }
        gen.writeEndArray();

        String requestId = abc_Logger.getRequestId();
        if (requestId == null) {
            gen.writeNullField('requestId');
        } else {
            gen.writeStringField('requestId', requestId);
        }

        gen.writeEndObject();
        return gen.getAsString();
    }

    /**
     * Writes status, content type and body onto the current REST response.
     * Tolerates a missing RestContext.response so the class can be unit tested
     * and so a handler never fails while reporting a failure.
     */
    public static void write(Integer statusCode, String body) {
        RestResponse res = RestContext.response;
        if (res == null) {
            res = new RestResponse();
            RestContext.response = res;
        }
        res.statusCode = statusCode;
        res.addHeader('Content-Type', CONTENT_TYPE_JSON);
        res.responseBody = Blob.valueOf(body);
    }
}
