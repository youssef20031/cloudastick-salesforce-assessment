/**
 * Tests for GET /services/apexrest/abc/v1/products at the HTTP edge.
 *
 * abc_ProductServiceTest already proves the catalogue rules. What is tested
 * here is everything the service cannot see: query parameters arriving as
 * strings, the response envelope, the status codes, and the fact that a bad
 * parameter produces a described 400 rather than a stack trace.
 */
@IsTest
private class abc_ProductRestResourceTest {
    private static final String BASE_URI = '/services/apexrest/abc/v1/products';

    private static void givenRequest(String uri, Map<String, String> params) {
        RestRequest request = new RestRequest();
        request.requestURI = uri;
        request.httpMethod = 'GET';
        if (params != null) {
            request.params.putAll(params);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    private static Map<String, Object> envelope() {
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }

    private static Map<String, Object> data() {
        return (Map<String, Object>) envelope().get('data');
    }

    private static String firstErrorCode() {
        List<Object> errors = (List<Object>) envelope().get('errors');
        return (String) ((Map<String, Object>) errors[0]).get('code');
    }

    private static void seedCatalogue() {
        List<Product2> products = new List<Product2>{
            abc_TestDataFactory.buildProduct('Paracetamol 500mg', 'ABC-MED-001', abc_TestDataFactory.CATEGORY_MEDICINE, 500, false),
            abc_TestDataFactory.buildProduct('Vitamin D3', 'ABC-SUP-001', abc_TestDataFactory.CATEGORY_SUPPLEMENT, 150, false),
            abc_TestDataFactory.buildProduct('Pulse Oximeter', 'ABC-DEV-001', abc_TestDataFactory.CATEGORY_MEDICAL_DEVICE, 0, false)
        };
        insert products;
        abc_TestDataFactory.createPricebookEntries(products);
    }

    // -------------------------------------------------------------- success

    @IsTest
    static void listingProductsReturns200AndTheDocumentedPayload() {
        seedCatalogue();
        givenRequest(BASE_URI, null);

        Test.startTest();
        abc_ProductRestResource.doGet();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual('application/json', RestContext.response.headers.get('Content-Type'));

        Map<String, Object> body = envelope();
        Assert.areEqual(true, body.get('success'));
        Assert.areEqual(0, ((List<Object>) body.get('errors')).size());
        Assert.isTrue(body.containsKey('requestId'));

        Map<String, Object> payload = data();
        Assert.isTrue(payload.containsKey('items'));
        Assert.areEqual(2, payload.get('count'), 'The zero-stock oximeter is hidden by default.');
        Assert.areEqual(50, payload.get('limit'), 'The default page size is 50.');
        Assert.areEqual(0, payload.get('offset'));

        Map<String, Object> first = (Map<String, Object>) ((List<Object>) payload.get('items'))[0];
        for (String key : new List<String>{
            'id', 'name', 'productCode', 'description', 'category',
            'requiresPrescription', 'stockQuantity', 'unitPrice', 'currencyIsoCode'
        }) {
            Assert.isTrue(first.containsKey(key), 'The product payload must keep the documented key "' + key + '".');
        }
    }

    @IsTest
    static void theRouteWorksWithoutTheApexrestPrefix() {
        seedCatalogue();
        givenRequest('/abc/v1/products', null);

        abc_ProductRestResource.doGet();

        Assert.areEqual(200, RestContext.response.statusCode, 'Both URI shapes reach the same endpoint.');
    }

    @IsTest
    static void queryParametersReachTheCatalogue() {
        seedCatalogue();
        givenRequest(BASE_URI, new Map<String, String>{ 'category' => 'Supplement' });

        Test.startTest();
        abc_ProductRestResource.doGet();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual(1, data().get('count'));
    }

    @IsTest
    static void includeOutOfStockBringsBackTheZeroStockProduct() {
        seedCatalogue();
        givenRequest(BASE_URI, new Map<String, String>{ 'includeOutOfStock' => 'true' });

        abc_ProductRestResource.doGet();

        Assert.areEqual(3, data().get('count'));
    }

    @IsTest
    static void searchAndPagingAreHonoured() {
        seedCatalogue();
        givenRequest(BASE_URI, new Map<String, String>{ 'search' => 'Vitamin', 'limit' => '1', 'offset' => '0' });

        abc_ProductRestResource.doGet();

        Map<String, Object> payload = data();
        Assert.areEqual(1, payload.get('count'));
        Assert.areEqual(1, payload.get('limit'));
    }

    @IsTest
    static void anOversizedLimitIsClampedRatherThanRejected() {
        seedCatalogue();
        givenRequest(BASE_URI, new Map<String, String>{ 'limit' => '9999' });

        abc_ProductRestResource.doGet();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual(200, data().get('limit'), 'The page size is capped at 200.');
    }

    // --------------------------------------------------------------- errors

    @IsTest
    static void aNonNumericLimitIs400InvalidInput() {
        seedCatalogue();
        givenRequest(BASE_URI, new Map<String, String>{ 'limit' => 'ten' });

        Test.startTest();
        abc_ProductRestResource.doGet();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_INVALID_INPUT, firstErrorCode());
        Assert.areEqual(false, envelope().get('success'));
        Assert.areEqual(null, envelope().get('data'));
    }

    @IsTest
    static void aZeroOrNegativeLimitIs400() {
        seedCatalogue();
        givenRequest(BASE_URI, new Map<String, String>{ 'limit' => '0' });
        abc_ProductRestResource.doGet();
        Assert.areEqual(400, RestContext.response.statusCode);

        givenRequest(BASE_URI, new Map<String, String>{ 'offset' => '-1' });
        abc_ProductRestResource.doGet();
        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_INVALID_INPUT, firstErrorCode());
    }

    @IsTest
    static void anAmbiguousBooleanIs400RatherThanAGuess() {
        seedCatalogue();
        givenRequest(BASE_URI, new Map<String, String>{ 'includeOutOfStock' => 'maybe' });

        abc_ProductRestResource.doGet();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_INVALID_INPUT, firstErrorCode());
    }

    @IsTest
    static void anUnknownSubPathIs404RouteNotFound() {
        seedCatalogue();
        givenRequest(BASE_URI + '/01t000000000000AAA/reviews', null);

        Test.startTest();
        abc_ProductRestResource.doGet();
        Test.stopTest();

        Assert.areEqual(404, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_ROUTE_NOT_FOUND, firstErrorCode());
    }

    @IsTest
    static void aClientErrorIsLoggedWithTheSameRequestIdItReturns() {
        seedCatalogue();
        givenRequest(BASE_URI, new Map<String, String>{ 'limit' => 'ten' });

        Test.startTest();
        abc_ProductRestResource.doGet();
        Test.stopTest();

        String returnedRequestId = (String) envelope().get('requestId');
        List<abc_Log__c> logs = [
            SELECT abc_Level__c, abc_Source__c, abc_Class__c, abc_Request_Id__c
            FROM abc_Log__c
            WHERE abc_Class__c = 'abc_ProductRestResource'
        ];
        Assert.areEqual(1, logs.size(), 'A rejected request should leave exactly one log entry.');
        Assert.areEqual(abc_Logger.LEVEL_WARN, logs[0].abc_Level__c, 'A client mistake is a warning, not an error.');
        Assert.areEqual(abc_Logger.SOURCE_REST, logs[0].abc_Source__c);
        Assert.areEqual(
            returnedRequestId,
            logs[0].abc_Request_Id__c,
            'The requestId in the response is what makes the log findable.'
        );
    }

    @IsTest
    static void anEmptyCatalogueStillReturns200WithAnEmptyList() {
        givenRequest(BASE_URI, null);

        abc_ProductRestResource.doGet();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual(0, data().get('count'));
    }
}
