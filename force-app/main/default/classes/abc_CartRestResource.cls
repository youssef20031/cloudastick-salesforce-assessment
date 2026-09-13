/**
 * The shopping cart endpoints for the Ionic app, all under
 * /services/apexrest/abc/v1/carts.
 *
 *   POST /abc/v1/carts                      create a cart          201 CartDto
 *   GET  /abc/v1/carts/{cartId}             read a cart            200 CartDto
 *   POST /abc/v1/carts/{cartId}/items       add a product          200 CartDto
 *   POST /abc/v1/carts/{cartId}/checkout    place the order        200 CartDto
 *
 * A cart is a Draft Order. Checkout activates that same Order, so nothing is
 * copied between a cart object and an order object and there is no window in
 * which the two could disagree.
 *
 * Apex REST allows one @HttpPost and one @HttpGet per class, so the four paths
 * are dispatched here on the part of the URI after the base path. An
 * unrecognised path is a 404 ROUTE_NOT_FOUND rather than a silent fallthrough,
 * so a client typo is reported instead of doing something surprising.
 *
 * Bodies are parsed with JSON.deserializeStrict against the request classes in
 * abc_ApiModels: an unknown attribute is rejected as MALFORMED_JSON rather than
 * quietly ignored, which stops a misspelled field from being read as absent.
 */
@RestResource(urlMapping='/abc/v1/carts/*')
global with sharing class abc_CartRestResource {
    private static final String CLASS_NAME = 'abc_CartRestResource';
    private static final String BASE_PATH = '/abc/v1/carts';
    private static final String ACTION_ITEMS = 'items';
    private static final String ACTION_CHECKOUT = 'checkout';

    // ------------------------------------------------------------------ POST

    @HttpPost
    global static void doPost() {
        abc_Logger.setSource(abc_Logger.SOURCE_REST);
        try {
            RestRequest request = RestContext.request;
            List<String> parts = abc_RestRouter.segments(request, BASE_PATH);

            if (parts.isEmpty()) {
                createCart(request);
            } else if (parts.size() == 2 && parts[1] == ACTION_ITEMS) {
                addItem(request, parts[0]);
            } else if (parts.size() == 2 && parts[1] == ACTION_CHECKOUT) {
                checkout(parts[0]);
            } else {
                throw abc_ApiException.routeNotFound(
                    'No such endpoint: POST ' +
                        BASE_PATH + '/' + String.join(parts, '/') +
                        '. Valid routes are POST ' + BASE_PATH +
                        ', POST ' + BASE_PATH + '/{cartId}/' + ACTION_ITEMS +
                        ' and POST ' + BASE_PATH + '/{cartId}/' + ACTION_CHECKOUT + '.'
                );
            }
        } catch (abc_ApiException known) {
            reportKnown('doPost', known);
        } catch (Exception unexpected) {
            reportUnexpected('doPost', 'Unhandled failure handling a cart POST', unexpected);
        } finally {
            abc_Logger.flush();
        }
    }

    // ------------------------------------------------------------------- GET

    @HttpGet
    global static void doGet() {
        abc_Logger.setSource(abc_Logger.SOURCE_REST);
        try {
            List<String> parts = abc_RestRouter.segments(RestContext.request, BASE_PATH);

            if (parts.size() != 1) {
                throw abc_ApiException.routeNotFound(
                    'No such endpoint: GET ' +
                        BASE_PATH + '/' + String.join(parts, '/') +
                        '. The only GET route is ' + BASE_PATH + '/{cartId}.'
                );
            }
            abc_RestResponse.ok(abc_CartService.getCart(parts[0]));
        } catch (abc_ApiException known) {
            reportKnown('doGet', known);
        } catch (Exception unexpected) {
            reportUnexpected('doGet', 'Unhandled failure reading a cart', unexpected);
        } finally {
            abc_Logger.flush();
        }
    }

    // -------------------------------------------------------------- handlers

    private static void createCart(RestRequest request) {
        abc_ApiModels.CreateCartRequest body = (abc_ApiModels.CreateCartRequest) parse(
            request,
            abc_ApiModels.CreateCartRequest.class,
            'a customer and an optional items array'
        );
        abc_RestResponse.created(abc_CartService.createCart(body));
    }

    private static void addItem(RestRequest request, String cartId) {
        abc_ApiModels.AddItemRequest body = (abc_ApiModels.AddItemRequest) parse(
            request,
            abc_ApiModels.AddItemRequest.class,
            'productId and quantity'
        );
        abc_RestResponse.ok(abc_CartService.addItem(cartId, body));
    }

    private static void checkout(String cartId) {
        // Checkout takes no body; anything sent with it is ignored on purpose,
        // so a client retrying with a stale payload cannot change the order.
        abc_RestResponse.ok(abc_CartService.checkout(cartId));
    }

    // --------------------------------------------------------------- helpers

    /**
     * Strict JSON parsing. deserializeStrict rejects any attribute that is not
     * declared on the target class, which turns a client-side typo into a clear
     * 400 instead of a field that silently never arrives.
     */
    private static Object parse(RestRequest request, System.Type target, String expected) {
        String raw = abc_RestRouter.body(request);
        if (raw == null) {
            throw abc_ApiException.invalidInput('A JSON request body is required, containing ' + expected + '.', null);
        }
        try {
            Object parsed = JSON.deserializeStrict(raw, target);
            if (parsed == null) {
                throw abc_ApiException.malformedJson('The request body was empty JSON; expected ' + expected + '.');
            }
            return parsed;
        } catch (JSONException badJson) {
            throw abc_ApiException.malformedJson(
                'The request body is not valid JSON for this endpoint (' + expected + '): ' + badJson.getMessage()
            );
        } catch (TypeException badType) {
            throw abc_ApiException.malformedJson(
                'The request body has the wrong shape for this endpoint (' + expected + '): ' + badType.getMessage()
            );
        }
    }

    private static void reportKnown(String methodName, abc_ApiException known) {
        abc_RestResponse.fail(known);
        String summary = known.errorCode + ': ' + known.getMessage() + ' (HTTP ' + known.httpStatus + ')';
        if (known.httpStatus != null && known.httpStatus >= 500) {
            abc_Logger.error(CLASS_NAME, methodName, summary, known, null, known.httpStatus);
        } else {
            abc_Logger.warn(CLASS_NAME, methodName, summary);
        }
    }

    private static void reportUnexpected(String methodName, String what, Exception unexpected) {
        // The caller gets a generic message; the detail stays in abc_Log__c,
        // reachable by the requestId returned in the envelope.
        abc_RestResponse.fail(
            500,
            abc_ApiException.CODE_INTERNAL_ERROR,
            'The request could not be completed. Quote the requestId when reporting this.',
            null
        );
        abc_Logger.error(CLASS_NAME, methodName, what, unexpected, null, 500);
    }
}
