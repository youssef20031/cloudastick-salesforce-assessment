/**
 * Tests for the two classes that define the shape of every ABC REST response:
 * abc_RestResponse (the envelope writer) and abc_ApiException (the error code
 * to HTTP status contract published to the Ionic developers).
 *
 * The envelope is a published contract, so these tests assert on the parsed
 * JSON rather than on substrings: if a key is renamed or stops being emitted,
 * a test here fails before any client notices.
 */
@IsTest
private class abc_RestResponseTest {
    private static Map<String, Object> parseBody(String body) {
        return (Map<String, Object>) JSON.deserializeUntyped(body);
    }

    private static void givenARestContext() {
        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();
    }

    private static Map<String, Object> sentBody() {
        return parseBody(RestContext.response.responseBody.toString());
    }

    // ------------------------------------------------------------- envelope

    @IsTest
    static void successEnvelopeCarriesDataAnEmptyErrorArrayAndARequestId() {
        givenARestContext();

        Test.startTest();
        abc_RestResponse.ok(new Map<String, Object>{ 'answer' => 42 });
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual('application/json', RestContext.response.headers.get('Content-Type'));

        Map<String, Object> body = sentBody();
        Assert.areEqual(true, body.get('success'));
        Assert.areEqual(42, ((Map<String, Object>) body.get('data')).get('answer'));
        Assert.areEqual(0, ((List<Object>) body.get('errors')).size(), 'A success carries an empty errors array.');
        Assert.isTrue(body.containsKey('requestId'), 'Every response carries a correlation id.');
        Assert.areEqual(abc_Logger.getRequestId(), body.get('requestId'), 'It is the same id the logs are stamped with.');
    }

    @IsTest
    static void createdUses201ForANewlyOpenedCart() {
        givenARestContext();

        abc_RestResponse.created(new Map<String, Object>{ 'cartId' => '801000000000000AAA' });

        Assert.areEqual(201, RestContext.response.statusCode, 'Creating a cart is a 201, not a 200.');
        Assert.areEqual(true, sentBody().get('success'));
    }

    @IsTest
    static void anEmptyPayloadIsSerialisedAsNullRatherThanOmitted() {
        givenARestContext();

        abc_RestResponse.ok(null);

        Map<String, Object> body = sentBody();
        Assert.isTrue(body.containsKey('data'), 'data must always be present, even when there is none.');
        Assert.areEqual(null, body.get('data'), 'A client should never have to tell absent from null.');
    }

    // --------------------------------------------------------------- errors

    @IsTest
    static void failureEnvelopeCarriesTheCodeMessageAndField() {
        givenARestContext();

        Test.startTest();
        abc_RestResponse.fail(abc_ApiException.validationError('quantity must be greater than zero.', 'quantity'));
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode);
        Map<String, Object> body = sentBody();
        Assert.areEqual(false, body.get('success'));
        Assert.areEqual(null, body.get('data'), 'A failure carries no data.');

        List<Object> errors = (List<Object>) body.get('errors');
        Assert.areEqual(1, errors.size());
        Map<String, Object> error = (Map<String, Object>) errors[0];
        Assert.areEqual(abc_ApiException.CODE_VALIDATION_ERROR, error.get('code'));
        Assert.areEqual('quantity must be greater than zero.', error.get('message'));
        Assert.areEqual('quantity', error.get('field'));
    }

    @IsTest
    static void anErrorWithNoParticularFieldOmitsTheFieldKey() {
        givenARestContext();

        abc_RestResponse.fail(abc_ApiException.routeNotFound('No such endpoint.'));

        Map<String, Object> error = (Map<String, Object>) ((List<Object>) sentBody().get('errors'))[0];
        Assert.areEqual(abc_ApiException.CODE_ROUTE_NOT_FOUND, error.get('code'));
        Assert.isFalse(error.containsKey('field'), 'field is optional and should be absent, not null.');
    }

    @IsTest
    static void failCanBeCalledWithAnExplicitStatusAndCode() {
        givenARestContext();

        abc_RestResponse.fail(503, 'SERVICE_BUSY', 'Try again shortly.', null);

        Assert.areEqual(503, RestContext.response.statusCode);
        Map<String, Object> error = (Map<String, Object>) ((List<Object>) sentBody().get('errors'))[0];
        Assert.areEqual('SERVICE_BUSY', error.get('code'));
    }

    @IsTest
    static void writingAResponseWithoutARestContextDoesNotThrow() {
        // A handler must never fail while reporting a failure.
        RestContext.response = null;

        abc_RestResponse.write(500, abc_RestResponse.buildErrorBody(new List<abc_RestResponse.ApiError>()));

        Assert.isNotNull(RestContext.response, 'A response is created on demand.');
        Assert.areEqual(500, RestContext.response.statusCode);
    }

    @IsTest
    static void anErrorWithNoCodeFallsBackToInternalError() {
        String body = abc_RestResponse.buildErrorBody(
            new List<abc_RestResponse.ApiError>{ new abc_RestResponse.ApiError(null, null, null) }
        );

        Map<String, Object> error = (Map<String, Object>) ((List<Object>) parseBody(body).get('errors'))[0];
        Assert.areEqual(abc_ApiException.CODE_INTERNAL_ERROR, error.get('code'), 'An unclassified error is a server fault.');
        Assert.areEqual('', error.get('message'), 'A missing message becomes empty, never the literal null.');
    }

    // ----------------------------------------------- the published contract

    @IsTest
    static void everyErrorCodeMapsToTheDocumentedHttpStatus() {
        Map<String, Integer> expected = new Map<String, Integer>{
            abc_ApiException.CODE_INVALID_INPUT => 400,
            abc_ApiException.CODE_MALFORMED_JSON => 400,
            abc_ApiException.CODE_VALIDATION_ERROR => 400,
            abc_ApiException.CODE_CART_NOT_FOUND => 404,
            abc_ApiException.CODE_PRODUCT_NOT_FOUND => 404,
            abc_ApiException.CODE_ROUTE_NOT_FOUND => 404,
            abc_ApiException.CODE_CART_NOT_EDITABLE => 409,
            abc_ApiException.CODE_INSUFFICIENT_STOCK => 409,
            abc_ApiException.CODE_INTERNAL_ERROR => 500
        };
        for (String code : expected.keySet()) {
            Assert.areEqual(
                expected.get(code),
                abc_ApiException.statusFor(code),
                code + ' must keep the status the API documentation promises.'
            );
        }
    }

    @IsTest
    static void anUnknownCodeIsTreatedAsAServerFaultNotASuccess() {
        Assert.areEqual(500, abc_ApiException.statusFor('SOMETHING_NEW'), 'Unknown codes must never become a 2xx.');
        Assert.areEqual(500, abc_ApiException.statusFor(null));
    }

    @IsTest
    static void eachFactoryProducesItsCodeStatusAndField() {
        Assert.areEqual(abc_ApiException.CODE_INVALID_INPUT, abc_ApiException.invalidInput('m', 'f').errorCode);
        Assert.areEqual('f', abc_ApiException.invalidInput('m', 'f').errorField);
        Assert.areEqual(abc_ApiException.CODE_MALFORMED_JSON, abc_ApiException.malformedJson('m').errorCode);
        Assert.areEqual(abc_ApiException.CODE_VALIDATION_ERROR, abc_ApiException.validationError('m', 'f').errorCode);
        Assert.areEqual('cartId', abc_ApiException.cartNotFound('m').errorField);
        Assert.areEqual('productId', abc_ApiException.productNotFound('m').errorField);
        Assert.areEqual(abc_ApiException.CODE_ROUTE_NOT_FOUND, abc_ApiException.routeNotFound('m').errorCode);
        Assert.areEqual('status', abc_ApiException.cartNotEditable('m').errorField);
        Assert.areEqual('quantity', abc_ApiException.insufficientStock('m').errorField);
        Assert.areEqual(500, abc_ApiException.internalError('m').httpStatus);
    }

    @IsTest
    static void anExceptionWithNoMessageFallsBackToItsCode() {
        abc_ApiException blank = abc_ApiException.build(abc_ApiException.CODE_INVALID_INPUT, '   ', null);
        Assert.areEqual(
            abc_ApiException.CODE_INVALID_INPUT,
            blank.getMessage(),
            'An error must always say something, even if the thrower did not.'
        );
    }
}
