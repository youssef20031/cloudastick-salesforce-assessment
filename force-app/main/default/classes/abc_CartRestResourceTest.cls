/**
 * Tests for the cart endpoints at the HTTP edge:
 *
 *   POST /abc/v1/carts                     201
 *   GET  /abc/v1/carts/{cartId}            200
 *   POST /abc/v1/carts/{cartId}/items      200
 *   POST /abc/v1/carts/{cartId}/checkout   200
 *
 * abc_CartServiceTest proves the cart rules. This class proves the things only
 * the edge can get wrong: dispatching four routes through one @HttpPost, strict
 * JSON parsing, the status code each error maps to, and the envelope the Ionic
 * app parses.
 */
@IsTest
private class abc_CartRestResourceTest {
    private static final String BASE_URI = '/services/apexrest/abc/v1/carts';

    private static List<Product2> products;
    private static List<PricebookEntry> entries;

    private static void seedCatalogue() {
        products = abc_TestDataFactory.createProducts(3);
        entries = abc_TestDataFactory.queryPricebookEntries(products);
    }

    private static void givenPost(String uri, String body) {
        RestRequest request = new RestRequest();
        request.requestURI = uri;
        request.httpMethod = 'POST';
        if (body != null) {
            request.requestBody = Blob.valueOf(body);
        }
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    private static void givenGet(String uri) {
        RestRequest request = new RestRequest();
        request.requestURI = uri;
        request.httpMethod = 'GET';
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
        return (String) ((Map<String, Object>) ((List<Object>) envelope().get('errors'))[0]).get('code');
    }

    private static String customerJson() {
        return '"customer":{"email":"mona.hassan@example.com","firstName":"Mona","lastName":"Hassan","phone":"+20 100 111 2222"}';
    }

    /** Creates a cart through the endpoint and returns its id. */
    private static String createCartViaApi() {
        givenPost(BASE_URI, '{' + customerJson() + '}');
        abc_CartRestResource.doPost();
        Assert.areEqual(201, RestContext.response.statusCode, 'Setup failed: ' + RestContext.response.responseBody.toString());
        return (String) data().get('cartId');
    }

    // --------------------------------------------------------- create cart

    @IsTest
    static void creatingACartReturns201AndTheCartPayload() {
        seedCatalogue();
        givenPost(BASE_URI, '{' + customerJson() + '}');

        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(201, RestContext.response.statusCode, 'Creating a resource is a 201.');
        Map<String, Object> body = envelope();
        Assert.areEqual(true, body.get('success'));
        Assert.isTrue(body.containsKey('requestId'));

        Map<String, Object> cart = data();
        for (String key : new List<String>{
            'cartId', 'orderNumber', 'status', 'customer', 'items', 'totalAmount', 'createdDate'
        }) {
            Assert.isTrue(cart.containsKey(key), 'CartDto must keep the documented key "' + key + '".');
        }
        Assert.areEqual('Draft', cart.get('status'));

        Map<String, Object> who = (Map<String, Object>) cart.get('customer');
        Assert.areEqual('mona.hassan@example.com', who.get('email'));
        Assert.isNotNull(who.get('accountId'));
        Assert.isNotNull(who.get('contactId'));
    }

    @IsTest
    static void aCartCanBeCreatedWithItemsInOneCall() {
        seedCatalogue();
        givenPost(
            BASE_URI,
            '{' + customerJson() + ',"items":[{"productId":"' + products[0].Id + '","quantity":2},' +
                '{"productId":"' + products[1].Id + '","quantity":1}]}'
        );

        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(201, RestContext.response.statusCode);
        Assert.areEqual(2, ((List<Object>) data().get('items')).size());
    }

    @IsTest
    static void theRouteWorksWithoutTheApexrestPrefixAndWithATrailingSlash() {
        seedCatalogue();

        givenPost('/abc/v1/carts', '{' + customerJson() + '}');
        abc_CartRestResource.doPost();
        Assert.areEqual(201, RestContext.response.statusCode, 'The bare path must reach create.');

        givenPost(BASE_URI + '/', '{' + customerJson() + '}');
        abc_CartRestResource.doPost();
        Assert.areEqual(201, RestContext.response.statusCode, 'A trailing slash is still the collection.');
    }

    // ----------------------------------------------------------- read cart

    @IsTest
    static void readingACartReturns200() {
        seedCatalogue();
        String cartId = createCartViaApi();

        givenGet(BASE_URI + '/' + cartId);
        Test.startTest();
        abc_CartRestResource.doGet();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual(cartId, data().get('cartId'));
    }

    @IsTest
    static void readingAnUnknownCartIs404() {
        seedCatalogue();
        givenGet(BASE_URI + '/801000000000001AAA');

        Test.startTest();
        abc_CartRestResource.doGet();
        Test.stopTest();

        Assert.areEqual(404, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_CART_NOT_FOUND, firstErrorCode());
    }

    @IsTest
    static void aGetWithoutACartIdIs404RouteNotFound() {
        seedCatalogue();

        givenGet(BASE_URI);
        abc_CartRestResource.doGet();
        Assert.areEqual(404, RestContext.response.statusCode, 'There is no "list all carts" endpoint.');
        Assert.areEqual(abc_ApiException.CODE_ROUTE_NOT_FOUND, firstErrorCode());

        givenGet(BASE_URI + '/801000000000001AAA/items');
        abc_CartRestResource.doGet();
        Assert.areEqual(404, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_ROUTE_NOT_FOUND, firstErrorCode());
    }

    // ------------------------------------------------------------ add item

    @IsTest
    static void addingAnItemReturns200AndTheUpdatedCart() {
        seedCatalogue();
        String cartId = createCartViaApi();

        givenPost(BASE_URI + '/' + cartId + '/items', '{"productId":"' + products[0].Id + '","quantity":3}');
        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode, 'Adding to an existing cart is a 200, not a 201.');
        List<Object> items = (List<Object>) data().get('items');
        Assert.areEqual(1, items.size());
        Assert.areEqual(3, ((Map<String, Object>) items[0]).get('quantity'));
    }

    @IsTest
    static void addingTheSameProductAgainMergesTheLine() {
        seedCatalogue();
        String cartId = createCartViaApi();
        String uri = BASE_URI + '/' + cartId + '/items';
        String body = '{"productId":"' + products[0].Id + '","quantity":2}';

        givenPost(uri, body);
        abc_CartRestResource.doPost();
        givenPost(uri, body);

        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        List<Object> items = (List<Object>) data().get('items');
        Assert.areEqual(1, items.size(), 'One line per product.');
        Assert.areEqual(4, ((Map<String, Object>) items[0]).get('quantity'));
    }

    @IsTest
    static void addingToAnUnknownCartIs404() {
        seedCatalogue();
        givenPost(BASE_URI + '/801000000000001AAA/items', '{"productId":"' + products[0].Id + '","quantity":1}');

        abc_CartRestResource.doPost();

        Assert.areEqual(404, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_CART_NOT_FOUND, firstErrorCode());
    }

    @IsTest
    static void addingAnUnknownProductIs404() {
        seedCatalogue();
        String cartId = createCartViaApi();
        givenPost(BASE_URI + '/' + cartId + '/items', '{"productId":"01t000000000000AAA","quantity":1}');

        abc_CartRestResource.doPost();

        Assert.areEqual(404, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_PRODUCT_NOT_FOUND, firstErrorCode());
    }

    @IsTest
    static void aZeroQuantityIs400() {
        seedCatalogue();
        String cartId = createCartViaApi();
        givenPost(BASE_URI + '/' + cartId + '/items', '{"productId":"' + products[0].Id + '","quantity":0}');

        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_VALIDATION_ERROR, firstErrorCode());
        Map<String, Object> error = (Map<String, Object>) ((List<Object>) envelope().get('errors'))[0];
        Assert.areEqual('quantity', error.get('field'), 'The client is told which field to fix.');
    }

    @IsTest
    static void orderingMoreThanTheWarehouseHasIs409() {
        Product2 scarce = abc_TestDataFactory.buildProduct(
            'Scarce Remedy',
            'ABC-SCARCE-1',
            abc_TestDataFactory.CATEGORY_MEDICINE,
            2,
            false
        );
        insert scarce;
        abc_TestDataFactory.createPricebookEntry(scarce, 99);
        String cartId = createCartViaApi();

        givenPost(BASE_URI + '/' + cartId + '/items', '{"productId":"' + scarce.Id + '","quantity":5}');
        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(409, RestContext.response.statusCode, 'Not enough stock is a conflict, not a bad request.');
        Assert.areEqual(abc_ApiException.CODE_INSUFFICIENT_STOCK, firstErrorCode());
    }

    @IsTest
    static void changingACartThatHasBeenCheckedOutIs409() {
        seedCatalogue();
        String cartId = createCartViaApi();
        givenPost(BASE_URI + '/' + cartId + '/items', '{"productId":"' + products[0].Id + '","quantity":1}');
        abc_CartRestResource.doPost();
        givenPost(BASE_URI + '/' + cartId + '/checkout', null);
        abc_CartRestResource.doPost();

        givenPost(BASE_URI + '/' + cartId + '/items', '{"productId":"' + products[1].Id + '","quantity":1}');
        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(409, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_CART_NOT_EDITABLE, firstErrorCode());
    }

    // ------------------------------------------------------------ checkout

    @IsTest
    static void checkoutReturns200AndAnActivatedOrder() {
        seedCatalogue();
        String cartId = createCartViaApi();
        givenPost(BASE_URI + '/' + cartId + '/items', '{"productId":"' + products[0].Id + '","quantity":2}');
        abc_CartRestResource.doPost();

        givenPost(BASE_URI + '/' + cartId + '/checkout', null);
        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual('Activated', data().get('status'));
        Assert.areEqual(cartId, data().get('cartId'), 'Checkout activates the same order.');
    }

    @IsTest
    static void checkingOutAnEmptyCartIs400() {
        seedCatalogue();
        String cartId = createCartViaApi();

        givenPost(BASE_URI + '/' + cartId + '/checkout', null);
        abc_CartRestResource.doPost();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_VALIDATION_ERROR, firstErrorCode());
    }

    // --------------------------------------------------------- bad requests

    @IsTest
    static void aMissingBodyIs400() {
        seedCatalogue();
        givenPost(BASE_URI, null);

        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_INVALID_INPUT, firstErrorCode());
    }

    @IsTest
    static void aBodyThatIsNotJsonIs400MalformedJson() {
        seedCatalogue();
        givenPost(BASE_URI, 'this is not json at all');

        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_MALFORMED_JSON, firstErrorCode());
    }

    @IsTest
    static void anUnexpectedAttributeIsRejectedRatherThanIgnored() {
        seedCatalogue();
        // "quantityy" is a typo. Lenient parsing would read the quantity as
        // absent and fail confusingly later; strict parsing says so immediately.
        String cartId = createCartViaApi();
        givenPost(BASE_URI + '/' + cartId + '/items', '{"productId":"' + products[0].Id + '","quantityy":2}');

        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_MALFORMED_JSON, firstErrorCode());
    }

    @IsTest
    static void aBodyOfTheWrongShapeIs400() {
        seedCatalogue();
        // quantity should be a number, not an object.
        String cartId = createCartViaApi();
        givenPost(BASE_URI + '/' + cartId + '/items', '{"productId":"' + products[0].Id + '","quantity":{"a":1}}');

        abc_CartRestResource.doPost();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_MALFORMED_JSON, firstErrorCode());
    }

    @IsTest
    static void anUnknownPostRouteIs404WithGuidance() {
        seedCatalogue();
        givenPost(BASE_URI + '/801000000000001AAA/gift-wrap', '{}');

        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        Assert.areEqual(404, RestContext.response.statusCode);
        Assert.areEqual(abc_ApiException.CODE_ROUTE_NOT_FOUND, firstErrorCode());
        String message = (String) ((Map<String, Object>) ((List<Object>) envelope().get('errors'))[0]).get('message');
        Assert.isTrue(message.contains('checkout'), 'A 404 should tell the client what the valid routes are.');
    }

    @IsTest
    static void everyRejectedRequestIsLoggedAgainstTheReturnedRequestId() {
        seedCatalogue();
        givenPost(BASE_URI, 'not json');

        Test.startTest();
        abc_CartRestResource.doPost();
        Test.stopTest();

        String returnedRequestId = (String) envelope().get('requestId');
        List<abc_Log__c> logs = [
            SELECT abc_Level__c, abc_Source__c, abc_Request_Id__c, abc_Class__c
            FROM abc_Log__c
            WHERE abc_Class__c = 'abc_CartRestResource'
        ];
        Assert.areEqual(1, logs.size(), 'The rejection should be logged once.');
        Assert.areEqual(abc_Logger.LEVEL_WARN, logs[0].abc_Level__c);
        Assert.areEqual(abc_Logger.SOURCE_REST, logs[0].abc_Source__c);
        Assert.areEqual(returnedRequestId, logs[0].abc_Request_Id__c);
    }
}
