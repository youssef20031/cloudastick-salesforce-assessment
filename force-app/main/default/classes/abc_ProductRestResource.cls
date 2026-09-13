/**
 * GET /services/apexrest/abc/v1/products
 *
 * The catalogue endpoint the Ionic app calls to render its product list.
 *
 * Query parameters (all optional):
 *   search             substring matched against product name and product code
 *   category           Medicine | Supplement | Personal Care | Medical Device
 *   includeOutOfStock  true to include products with zero stock (default false)
 *   limit              page size, 1-200 (default 50)
 *   offset             rows to skip (default 0)
 *
 * 200 data:
 *   { "items": [ { id, name, productCode, description, category,
 *                  requiresPrescription, stockQuantity, unitPrice,
 *                  currencyIsoCode } ],
 *     "count": n, "limit": n, "offset": n }
 *
 * The class is a thin edge: read the request, call abc_ProductService, write
 * the envelope. All catalogue rules live in the service so they can be tested
 * without a RestContext.
 */
@RestResource(urlMapping='/abc/v1/products/*')
global with sharing class abc_ProductRestResource {
    private static final String CLASS_NAME = 'abc_ProductRestResource';
    private static final String BASE_PATH = '/abc/v1/products';

    @HttpGet
    global static void doGet() {
        abc_Logger.setSource(abc_Logger.SOURCE_REST);
        try {
            RestRequest request = RestContext.request;

            // The catalogue has no sub-resources; anything deeper is a client bug.
            String suffix = abc_RestRouter.suffix(request, BASE_PATH);
            if (String.isNotBlank(suffix)) {
                throw abc_ApiException.routeNotFound(
                    'No such endpoint: GET ' + BASE_PATH + '/' + suffix + '. Did you mean GET ' + BASE_PATH + '?'
                );
            }

            abc_ProductService.ProductQuery criteria = new abc_ProductService.ProductQuery();
            criteria.search = abc_RestRouter.param(request, 'search');
            criteria.category = abc_RestRouter.param(request, 'category');

            Boolean includeOutOfStock = abc_RestRouter.boolParam(request, 'includeOutOfStock');
            criteria.includeOutOfStock = includeOutOfStock == true;

            Integer pageSize = abc_RestRouter.intParam(request, 'limit');
            if (pageSize != null) {
                if (pageSize < 1) {
                    throw abc_ApiException.invalidInput('limit must be at least 1.', 'limit');
                }
                criteria.pageSize = pageSize;
            }

            Integer pageOffset = abc_RestRouter.intParam(request, 'offset');
            if (pageOffset != null) {
                if (pageOffset < 0) {
                    throw abc_ApiException.invalidInput('offset cannot be negative.', 'offset');
                }
                criteria.pageOffset = pageOffset;
            }

            abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(criteria);
            abc_RestResponse.ok(page.toPayload());
        } catch (abc_ApiException known) {
            abc_RestResponse.fail(known);
            abc_Logger.warn(
                CLASS_NAME,
                'doGet',
                known.errorCode + ': ' + known.getMessage() + ' (HTTP ' + known.httpStatus + ')'
            );
        } catch (Exception unexpected) {
            abc_RestResponse.fail(
                500,
                abc_ApiException.CODE_INTERNAL_ERROR,
                'The product list could not be retrieved. Quote the requestId when reporting this.',
                null
            );
            abc_Logger.error(CLASS_NAME, 'doGet', 'Unhandled failure listing products', unexpected, null, 500);
        } finally {
            abc_Logger.flush();
        }
    }
}
