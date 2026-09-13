/**
 * The one exception the ABC REST layer throws on purpose.
 *
 * Every failure a caller is allowed to see is expressed as an abc_ApiException
 * carrying a stable machine-readable code, the HTTP status that code maps to,
 * and optionally the request field at fault. The resource classes catch it,
 * hand it to abc_RestResponse and log it - so the mapping from business rule to
 * HTTP status lives here and nowhere else.
 *
 * Anything else that escapes a handler is a bug, and is reported to the caller
 * as a generic 500 INTERNAL_ERROR with the detail kept in abc_Log__c.
 *
 * Apex exception classes cannot declare their own constructors, so instances
 * are built through the static factory methods below.
 */
public class abc_ApiException extends Exception {
    public static final String CODE_INVALID_INPUT = 'INVALID_INPUT';
    public static final String CODE_MALFORMED_JSON = 'MALFORMED_JSON';
    public static final String CODE_VALIDATION_ERROR = 'VALIDATION_ERROR';
    public static final String CODE_CART_NOT_FOUND = 'CART_NOT_FOUND';
    public static final String CODE_PRODUCT_NOT_FOUND = 'PRODUCT_NOT_FOUND';
    public static final String CODE_ROUTE_NOT_FOUND = 'ROUTE_NOT_FOUND';
    public static final String CODE_CART_NOT_EDITABLE = 'CART_NOT_EDITABLE';
    public static final String CODE_INSUFFICIENT_STOCK = 'INSUFFICIENT_STOCK';
    public static final String CODE_INTERNAL_ERROR = 'INTERNAL_ERROR';

    /** The contract published to the Ionic developers: code -> HTTP status. */
    private static final Map<String, Integer> STATUS_BY_CODE = new Map<String, Integer>{
        CODE_INVALID_INPUT => 400,
        CODE_MALFORMED_JSON => 400,
        CODE_VALIDATION_ERROR => 400,
        CODE_CART_NOT_FOUND => 404,
        CODE_PRODUCT_NOT_FOUND => 404,
        CODE_ROUTE_NOT_FOUND => 404,
        CODE_CART_NOT_EDITABLE => 409,
        CODE_INSUFFICIENT_STOCK => 409,
        CODE_INTERNAL_ERROR => 500
    };

    /** Machine-readable error code returned in the envelope. */
    public String errorCode;

    /** Request field the error is about, when there is one. Optional in the envelope. */
    public String errorField;

    /** HTTP status the response is sent with. */
    public Integer httpStatus;

    /** 400: the request was not understood or a required value was missing. */
    public static abc_ApiException invalidInput(String message, String fieldName) {
        return build(CODE_INVALID_INPUT, message, fieldName);
    }

    /** 400: the body was not parseable as the JSON this endpoint expects. */
    public static abc_ApiException malformedJson(String message) {
        return build(CODE_MALFORMED_JSON, message, null);
    }

    /** 400: the request parsed, but a business rule rejected the values. */
    public static abc_ApiException validationError(String message, String fieldName) {
        return build(CODE_VALIDATION_ERROR, message, fieldName);
    }

    /** 404 */
    public static abc_ApiException cartNotFound(String message) {
        return build(CODE_CART_NOT_FOUND, message, 'cartId');
    }

    /** 404 */
    public static abc_ApiException productNotFound(String message) {
        return build(CODE_PRODUCT_NOT_FOUND, message, 'productId');
    }

    /** 404 */
    public static abc_ApiException routeNotFound(String message) {
        return build(CODE_ROUTE_NOT_FOUND, message, null);
    }

    /** 409: the cart has left Draft, so its contents are frozen. */
    public static abc_ApiException cartNotEditable(String message) {
        return build(CODE_CART_NOT_EDITABLE, message, 'status');
    }

    /** 409: the warehouse cannot satisfy the requested quantity. */
    public static abc_ApiException insufficientStock(String message) {
        return build(CODE_INSUFFICIENT_STOCK, message, 'quantity');
    }

    /** 500: never built from caller input; the detail belongs in abc_Log__c. */
    public static abc_ApiException internalError(String message) {
        return build(CODE_INTERNAL_ERROR, message, null);
    }

    public static abc_ApiException build(String code, String message, String fieldName) {
        abc_ApiException ex = new abc_ApiException(String.isBlank(message) ? code : message);
        ex.errorCode = code;
        ex.errorField = fieldName;
        ex.httpStatus = statusFor(code);
        return ex;
    }

    /** Unknown codes are treated as server faults rather than silently becoming 200. */
    public static Integer statusFor(String code) {
        Integer status = STATUS_BY_CODE.get(code);
        return status == null ? 500 : status;
    }
}
