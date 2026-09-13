/**
 * Catalogue reads for the Ionic app.
 *
 * A product is only sellable when it is active AND has an active entry in the
 * standard price book, so the query is driven from PricebookEntry rather than
 * Product2: that single join decides visibility and supplies the price in one
 * SOQL call. Out-of-stock products are hidden unless the caller asks for them,
 * because the app's default catalogue view should only show what can be bought.
 *
 * Sharing and field-level security are enforced: the class is with sharing and
 * every query runs in user mode, so the integration user sees exactly what the
 * abc_API_Integration permission set allows and nothing more.
 */
public with sharing class abc_ProductService {
    private static final String CLASS_NAME = 'abc_ProductService';

    /** Page size ceiling. A mobile list never needs more and the org is protected from scans. */
    public static final Integer MAX_PAGE_SIZE = 200;
    public static final Integer DEFAULT_PAGE_SIZE = 50;

    /** SOQL refuses an OFFSET beyond 2000 rows. */
    public static final Integer MAX_OFFSET = 2000;

    private static Id cachedPricebookId;

    /** Everything GET /abc/v1/products can be asked for, already parsed and validated. */
    public class ProductQuery {
        public String search;
        public String category;
        public Boolean includeOutOfStock = false;
        public Integer pageSize = DEFAULT_PAGE_SIZE;
        public Integer pageOffset = 0;
    }

    /**
     * One page of sellable products. Never throws for an empty catalogue; an
     * org without a standard price book simply has nothing to sell.
     */
    public static abc_ApiModels.ProductListDto listProducts(ProductQuery criteria) {
        ProductQuery params = criteria == null ? new ProductQuery() : criteria;

        Integer pageSize = params.pageSize == null ? DEFAULT_PAGE_SIZE : params.pageSize;
        pageSize = Math.min(Math.max(pageSize, 1), MAX_PAGE_SIZE);
        Integer pageOffset = params.pageOffset == null ? 0 : params.pageOffset;
        pageOffset = Math.min(Math.max(pageOffset, 0), MAX_OFFSET);

        abc_ApiModels.ProductListDto page = new abc_ApiModels.ProductListDto();
        page.pageSize = pageSize;
        page.pageOffset = pageOffset;

        Id pricebookId = standardPricebookId();
        if (pricebookId == null) {
            abc_Logger.warn(CLASS_NAME, 'listProducts', 'No standard price book in this org; catalogue is empty.');
            return page;
        }

        // Bind variables only - no caller input is ever concatenated into SOQL.
        Map<String, Object> binds = new Map<String, Object>{
            'pricebookId' => pricebookId,
            'pageSize' => pageSize,
            'pageOffset' => pageOffset
        };
        String soql =
            'SELECT Id, UnitPrice, Product2Id, Product2.Name, Product2.ProductCode, Product2.Description,' +
            ' Product2.abc_Category__c, Product2.abc_Requires_Prescription__c, Product2.abc_Stock_Quantity__c' +
            ' FROM PricebookEntry' +
            ' WHERE Pricebook2Id = :pricebookId AND IsActive = true AND Product2.IsActive = true';

        if (String.isNotBlank(params.search)) {
            binds.put('searchTerm', '%' + params.search.trim() + '%');
            soql += ' AND (Product2.Name LIKE :searchTerm OR Product2.ProductCode LIKE :searchTerm)';
        }
        if (String.isNotBlank(params.category)) {
            binds.put('category', params.category.trim());
            soql += ' AND Product2.abc_Category__c = :category';
        }
        if (params.includeOutOfStock != true) {
            soql += ' AND Product2.abc_Stock_Quantity__c > 0';
        }
        soql += ' ORDER BY Product2.Name ASC, Id ASC LIMIT :pageSize OFFSET :pageOffset';

        // "currency" is a reserved Apex identifier, hence currencyIsoCode.
        String currencyIsoCode = UserInfo.getDefaultCurrency();
        for (SObject row : Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE)) {
            page.items.add(toDto((PricebookEntry) row, currencyIsoCode));
        }
        page.count = page.items.size();
        return page;
    }

    private static abc_ApiModels.ProductDto toDto(PricebookEntry entry, String currencyIsoCode) {
        abc_ApiModels.ProductDto dto = new abc_ApiModels.ProductDto();
        dto.id = entry.Product2Id;
        dto.name = entry.Product2.Name;
        dto.productCode = entry.Product2.ProductCode;
        dto.description = entry.Product2.Description;
        dto.category = entry.Product2.abc_Category__c;
        dto.requiresPrescription = entry.Product2.abc_Requires_Prescription__c == true;
        dto.stockQuantity = entry.Product2.abc_Stock_Quantity__c == null ? 0 : entry.Product2.abc_Stock_Quantity__c;
        dto.unitPrice = entry.UnitPrice;
        dto.currencyIsoCode = currencyIsoCode;
        return dto;
    }

    /**
     * The org's standard price book - the only one this solution prices from.
     * Cached for the transaction; in a test the standard book is not returned
     * as an active row, hence the documented Test.getStandardPricebookId fallback.
     */
    public static Id standardPricebookId() {
        if (cachedPricebookId != null) {
            return cachedPricebookId;
        }
        List<Pricebook2> books = [SELECT Id FROM Pricebook2 WHERE IsStandard = true WITH USER_MODE LIMIT 1];
        if (!books.isEmpty()) {
            cachedPricebookId = books[0].Id;
        } else if (Test.isRunningTest()) {
            cachedPricebookId = Test.getStandardPricebookId();
        }
        return cachedPricebookId;
    }
}
