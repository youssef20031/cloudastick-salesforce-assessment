/**
 * Tests for abc_RestRouter, which extracts the routable part of a REST path.
 *
 * The awkwardness this class absorbs is real: requestURI arrives with or
 * without the /services/apexrest prefix depending on how the call was made,
 * with or without a trailing slash, and sometimes with a query string still
 * attached. Every one of those shapes has to reduce to the same route, or the
 * cart resource would 404 on a request that is perfectly valid.
 */
@IsTest
private class abc_RestRouterTest {
    private static final String CARTS = '/abc/v1/carts';

    private static RestRequest requestFor(String uri) {
        RestRequest request = new RestRequest();
        request.requestURI = uri;
        return request;
    }

    // ---------------------------------------------------------- suffix

    @IsTest
    static void theBasePathItselfHasAnEmptySuffix() {
        Assert.areEqual('', abc_RestRouter.suffix(requestFor('/abc/v1/carts'), CARTS));
        Assert.areEqual('', abc_RestRouter.suffix(requestFor('/abc/v1/carts/'), CARTS));
        Assert.areEqual(
            '',
            abc_RestRouter.suffix(requestFor('/services/apexrest/abc/v1/carts'), CARTS),
            'The apexrest prefix must not change the route.'
        );
    }

    @IsTest
    static void aSingleSegmentIsReturnedWithoutSlashes() {
        Assert.areEqual('801000000000001AAA', abc_RestRouter.suffix(requestFor(CARTS + '/801000000000001AAA'), CARTS));
        Assert.areEqual(
            '801000000000001AAA',
            abc_RestRouter.suffix(requestFor('/services/apexrest' + CARTS + '/801000000000001AAA/'), CARTS)
        );
    }

    @IsTest
    static void aNestedActionKeepsItsSegments() {
        Assert.areEqual('801000000000001AAA/items', abc_RestRouter.suffix(requestFor(CARTS + '/801000000000001AAA/items'), CARTS));
        Assert.areEqual(
            '801000000000001AAA/checkout',
            abc_RestRouter.suffix(requestFor(CARTS + '/801000000000001AAA/checkout'), CARTS)
        );
    }

    @IsTest
    static void aQueryStringIsNotPartOfTheRoute() {
        Assert.areEqual(
            '801000000000001AAA',
            abc_RestRouter.suffix(requestFor(CARTS + '/801000000000001AAA?expand=items'), CARTS),
            'A query string must not turn a valid route into a 404.'
        );
    }

    @IsTest
    static void aMissingRequestOrUriIsAnEmptySuffixRatherThanAnError() {
        Assert.areEqual('', abc_RestRouter.suffix(null, CARTS));
        Assert.areEqual('', abc_RestRouter.suffix(new RestRequest(), CARTS));
    }

    @IsTest
    static void segmentsDropEmptyPartsSoDoubleSlashesDoNotCreatePhantomRoutes() {
        List<String> parts = abc_RestRouter.segments(requestFor(CARTS + '//801000000000001AAA//items//'), CARTS);
        Assert.areEqual(2, parts.size(), 'Empty segments are noise, not routes: ' + parts);
        Assert.areEqual('801000000000001AAA', parts[0]);
        Assert.areEqual('items', parts[1]);
    }

    @IsTest
    static void segmentsOfTheBasePathIsAnEmptyList() {
        Assert.areEqual(0, abc_RestRouter.segments(requestFor(CARTS), CARTS).size());
    }

    // ------------------------------------------------------- parameters

    @IsTest
    static void parametersAreTrimmedAndBlanksReadAsAbsent() {
        RestRequest request = requestFor('/abc/v1/products');
        request.params.put('search', '  panadol  ');
        request.params.put('category', '   ');

        Assert.areEqual('panadol', abc_RestRouter.param(request, 'search'));
        Assert.areEqual(null, abc_RestRouter.param(request, 'category'), 'A blank parameter is the same as none.');
        Assert.areEqual(null, abc_RestRouter.param(request, 'missing'));
        Assert.areEqual(null, abc_RestRouter.param(null, 'search'));
    }

    @IsTest
    static void integerParametersParseOrAreReported() {
        RestRequest request = requestFor('/abc/v1/products');
        request.params.put('limit', '25');
        request.params.put('offset', 'lots');

        Assert.areEqual(25, abc_RestRouter.intParam(request, 'limit'));
        Assert.areEqual(null, abc_RestRouter.intParam(request, 'absent'));

        try {
            abc_RestRouter.intParam(request, 'offset');
            Assert.fail('A non-numeric page offset must be reported, not silently ignored.');
        } catch (abc_ApiException e) {
            Assert.areEqual(abc_ApiException.CODE_INVALID_INPUT, e.errorCode);
            Assert.areEqual('offset', e.errorField);
        }
    }

    @IsTest
    static void booleanParametersAcceptOnlyTrueOrFalse() {
        RestRequest request = requestFor('/abc/v1/products');
        request.params.put('a', 'TRUE');
        request.params.put('b', 'false');
        request.params.put('c', 'yes');

        Assert.areEqual(true, abc_RestRouter.boolParam(request, 'a'), 'Case should not matter.');
        Assert.areEqual(false, abc_RestRouter.boolParam(request, 'b'));
        Assert.areEqual(null, abc_RestRouter.boolParam(request, 'absent'));

        try {
            abc_RestRouter.boolParam(request, 'c');
            Assert.fail('"yes" is ambiguous and must be rejected rather than guessed at.');
        } catch (abc_ApiException e) {
            Assert.areEqual(abc_ApiException.CODE_INVALID_INPUT, e.errorCode);
        }
    }

    @IsTest
    static void bodyReadsTheRequestPayloadAndTreatsBlankAsAbsent() {
        RestRequest withBody = requestFor(CARTS);
        withBody.requestBody = Blob.valueOf('{"a":1}');
        Assert.areEqual('{"a":1}', abc_RestRouter.body(withBody));

        RestRequest blank = requestFor(CARTS);
        blank.requestBody = Blob.valueOf('   ');
        Assert.areEqual(null, abc_RestRouter.body(blank), 'Whitespace is not a body.');

        Assert.areEqual(null, abc_RestRouter.body(requestFor(CARTS)));
        Assert.areEqual(null, abc_RestRouter.body(null));
    }
}
