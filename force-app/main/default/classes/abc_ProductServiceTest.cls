/**
 * Tests for abc_ProductService - the catalogue the Ionic app reads.
 *
 * The service builds its SOQL dynamically to apply optional filters, so the
 * tests deliberately push on the filter combinations and the paging bounds:
 * that is where a dynamic query goes wrong, and it is the part a client can
 * reach directly through query parameters.
 */
@IsTest
private class abc_ProductServiceTest {
    private static Product2 paracetamol;
    private static Product2 vitaminD;
    private static Product2 sunscreen;
    private static Product2 outOfStock;
    private static Product2 inactive;

    /**
     * A small catalogue with one product of each interesting shape: two
     * medicines, a supplement, a personal-care item, one with no stock left and
     * one that has been withdrawn from sale.
     */
    private static void seedCatalogue() {
        List<Product2> products = new List<Product2>{
            abc_TestDataFactory.buildProduct('Paracetamol 500mg', 'ABC-MED-001', abc_TestDataFactory.CATEGORY_MEDICINE, 500, false),
            abc_TestDataFactory.buildProduct('Amoxicillin 250mg', 'ABC-MED-002', abc_TestDataFactory.CATEGORY_MEDICINE, 200, true),
            abc_TestDataFactory.buildProduct('Vitamin D3 1000IU', 'ABC-SUP-001', abc_TestDataFactory.CATEGORY_SUPPLEMENT, 150, false),
            abc_TestDataFactory.buildProduct('Sunscreen SPF 50', 'ABC-PC-001', abc_TestDataFactory.CATEGORY_PERSONAL_CARE, 75, false),
            abc_TestDataFactory.buildProduct('Pulse Oximeter', 'ABC-DEV-001', abc_TestDataFactory.CATEGORY_MEDICAL_DEVICE, 0, false),
            abc_TestDataFactory.buildProduct('Withdrawn Syrup', 'ABC-MED-999', abc_TestDataFactory.CATEGORY_MEDICINE, 50, false)
        };
        products[5].IsActive = false;
        insert products;

        paracetamol = products[0];
        vitaminD = products[2];
        sunscreen = products[3];
        outOfStock = products[4];
        inactive = products[5];

        Id pricebookId = abc_TestDataFactory.standardPricebookId();
        List<PricebookEntry> entries = new List<PricebookEntry>();
        Integer price = 10;
        for (Product2 p : products) {
            entries.add(
                new PricebookEntry(
                    Pricebook2Id = pricebookId,
                    Product2Id = p.Id,
                    UnitPrice = price,
                    IsActive = true,
                    UseStandardPrice = false
                )
            );
            price += 10;
        }
        insert entries;
    }

    private static Set<String> codesIn(abc_ApiModels.ProductListDto page) {
        Set<String> codes = new Set<String>();
        for (abc_ApiModels.ProductDto dto : page.items) {
            codes.add(dto.productCode);
        }
        return codes;
    }

    private static abc_ProductService.ProductQuery query() {
        return new abc_ProductService.ProductQuery();
    }

    // -------------------------------------------------------------- defaults

    @IsTest
    static void byDefaultTheCatalogueHidesOutOfStockAndInactiveProducts() {
        seedCatalogue();

        Test.startTest();
        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(query());
        Test.stopTest();

        Set<String> codes = codesIn(page);
        Assert.areEqual(4, page.items.size(), 'Four sellable products: ' + codes);
        Assert.isTrue(codes.contains('ABC-MED-001'));
        Assert.isFalse(codes.contains('ABC-DEV-001'), 'A product with no stock is not offered by default.');
        Assert.isFalse(codes.contains('ABC-MED-999'), 'A withdrawn product is never offered.');
        Assert.areEqual(page.items.size(), page.count, 'count reports the size of this page.');
        Assert.areEqual(abc_ProductService.DEFAULT_PAGE_SIZE, page.pageSize);
        Assert.areEqual(0, page.pageOffset);
    }

    @IsTest
    static void aNullQueryIsTreatedAsTheDefaultQuery() {
        seedCatalogue();

        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(null);

        Assert.areEqual(4, page.items.size(), 'No criteria means the default catalogue, not an error.');
    }

    @IsTest
    static void eachProductCarriesEverythingTheAppNeedsToRenderIt() {
        seedCatalogue();

        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(query());

        abc_ApiModels.ProductDto dto;
        for (abc_ApiModels.ProductDto candidate : page.items) {
            if (candidate.productCode == 'ABC-MED-001') {
                dto = candidate;
            }
        }
        Assert.isNotNull(dto, 'Paracetamol should be in the catalogue.');
        Assert.areEqual(paracetamol.Id, dto.id);
        Assert.areEqual('Paracetamol 500mg', dto.name);
        Assert.areEqual(abc_TestDataFactory.CATEGORY_MEDICINE, dto.category);
        Assert.areEqual(false, dto.requiresPrescription);
        Assert.areEqual(500, dto.stockQuantity);
        Assert.areEqual(10, dto.unitPrice, 'The price comes from the standard price book entry.');
        Assert.isNotNull(dto.currencyIsoCode);
        Assert.isNotNull(dto.description);
    }

    @IsTest
    static void prescriptionOnlyProductsAreFlaggedSoTheAppCanAskForOne() {
        seedCatalogue();

        abc_ProductService.ProductQuery criteria = query();
        criteria.search = 'Amoxicillin';
        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(criteria);

        Assert.areEqual(1, page.items.size());
        Assert.areEqual(true, page.items[0].requiresPrescription);
    }

    // --------------------------------------------------------------- filters

    @IsTest
    static void includeOutOfStockBringsBackZeroStockProductsButStillNotInactiveOnes() {
        seedCatalogue();

        abc_ProductService.ProductQuery criteria = query();
        criteria.includeOutOfStock = true;

        Test.startTest();
        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(criteria);
        Test.stopTest();

        Set<String> codes = codesIn(page);
        Assert.areEqual(5, page.items.size(), 'The out-of-stock product joins the four sellable ones: ' + codes);
        Assert.isTrue(codes.contains('ABC-DEV-001'), 'Zero stock is now included.');
        Assert.isFalse(codes.contains('ABC-MED-999'), 'Withdrawn is still withdrawn.');
    }

    @IsTest
    static void searchMatchesOnNameOrProductCodeAndIsCaseInsensitive() {
        seedCatalogue();

        abc_ProductService.ProductQuery byName = query();
        byName.search = 'vitamin';
        Assert.areEqual(1, abc_ProductService.listProducts(byName).items.size(), 'Name match should ignore case.');

        abc_ProductService.ProductQuery byCode = query();
        byCode.search = 'ABC-PC';
        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(byCode);
        Assert.areEqual(1, page.items.size(), 'Product code should be searchable too.');
        Assert.areEqual('ABC-PC-001', page.items[0].productCode);

        abc_ProductService.ProductQuery noMatch = query();
        noMatch.search = 'zzz-nothing-like-this';
        Assert.areEqual(0, abc_ProductService.listProducts(noMatch).items.size(), 'No match is an empty page, not an error.');
    }

    @IsTest
    static void searchIsBoundNotConcatenatedSoQuoteCharactersAreHarmless() {
        seedCatalogue();

        abc_ProductService.ProductQuery hostile = query();
        // If this were concatenated into the SOQL string it would break the query.
        hostile.search = '\' OR Name != NULL OR Name LIKE \'';

        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(hostile);

        Assert.areEqual(0, page.items.size(), 'Caller input is a bind variable, so it can only ever be data.');
    }

    @IsTest
    static void categoryNarrowsTheCatalogue() {
        seedCatalogue();

        abc_ProductService.ProductQuery criteria = query();
        criteria.category = abc_TestDataFactory.CATEGORY_MEDICINE;
        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(criteria);

        Assert.areEqual(2, page.items.size(), 'Two active, in-stock medicines: ' + codesIn(page));
        for (abc_ApiModels.ProductDto dto : page.items) {
            Assert.areEqual(abc_TestDataFactory.CATEGORY_MEDICINE, dto.category);
        }
    }

    @IsTest
    static void filtersCombine() {
        seedCatalogue();

        abc_ProductService.ProductQuery criteria = query();
        criteria.category = abc_TestDataFactory.CATEGORY_MEDICINE;
        criteria.search = 'Paracetamol';

        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(criteria);

        Assert.areEqual(1, page.items.size(), 'Both filters should apply, not just the last one.');
        Assert.areEqual('ABC-MED-001', page.items[0].productCode);
    }

    // ---------------------------------------------------------------- paging

    @IsTest
    static void pagingWalksTheCatalogueWithoutRepeatingOrSkipping() {
        seedCatalogue();

        abc_ProductService.ProductQuery firstPage = query();
        firstPage.pageSize = 2;
        firstPage.pageOffset = 0;

        abc_ProductService.ProductQuery secondPage = query();
        secondPage.pageSize = 2;
        secondPage.pageOffset = 2;

        Set<String> first = codesIn(abc_ProductService.listProducts(firstPage));
        Set<String> second = codesIn(abc_ProductService.listProducts(secondPage));

        Assert.areEqual(2, first.size());
        Assert.areEqual(2, second.size());
        Set<String> overlap = first.clone();
        overlap.retainAll(second);
        Assert.areEqual(0, overlap.size(), 'Pages must not overlap: ' + first + ' vs ' + second);
    }

    @IsTest
    static void pageSizeIsClampedIntoTheSupportedRange() {
        seedCatalogue();

        abc_ProductService.ProductQuery tooBig = query();
        tooBig.pageSize = 5000;
        Assert.areEqual(
            abc_ProductService.MAX_PAGE_SIZE,
            abc_ProductService.listProducts(tooBig).pageSize,
            'An oversized page is clamped, not rejected, so a client cannot pull the whole catalogue.'
        );

        abc_ProductService.ProductQuery tooSmall = query();
        tooSmall.pageSize = 0;
        Assert.areEqual(1, abc_ProductService.listProducts(tooSmall).pageSize, 'A page must hold at least one row.');

        abc_ProductService.ProductQuery negative = query();
        negative.pageSize = -10;
        Assert.areEqual(1, abc_ProductService.listProducts(negative).pageSize);

        abc_ProductService.ProductQuery unset = query();
        unset.pageSize = null;
        Assert.areEqual(abc_ProductService.DEFAULT_PAGE_SIZE, abc_ProductService.listProducts(unset).pageSize);
    }

    @IsTest
    static void offsetIsClampedToTheRangeSoqlAllows() {
        seedCatalogue();

        abc_ProductService.ProductQuery negative = query();
        negative.pageOffset = -5;
        Assert.areEqual(0, abc_ProductService.listProducts(negative).pageOffset);

        abc_ProductService.ProductQuery huge = query();
        huge.pageOffset = 999999;
        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(huge);
        Assert.areEqual(
            abc_ProductService.MAX_OFFSET,
            page.pageOffset,
            'SOQL caps OFFSET at 2000; going past it must clamp rather than throw.'
        );
        Assert.areEqual(0, page.items.size());

        abc_ProductService.ProductQuery unset = query();
        unset.pageOffset = null;
        Assert.areEqual(0, abc_ProductService.listProducts(unset).pageOffset);
    }

    // --------------------------------------------------------------- payload

    @IsTest
    static void theJsonPayloadUsesTheDocumentedKeyNames() {
        seedCatalogue();

        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(query());
        Map<String, Object> payload = page.toPayload();

        Assert.isTrue(payload.containsKey('items'));
        Assert.isTrue(payload.containsKey('count'));
        Assert.isTrue(payload.containsKey('limit'), 'The wire name is "limit", even though Apex cannot use it.');
        Assert.isTrue(payload.containsKey('offset'), 'The wire name is "offset".');
        Assert.areEqual(page.items.size(), payload.get('count'));
        Assert.areEqual(abc_ProductService.DEFAULT_PAGE_SIZE, payload.get('limit'));
    }

    @IsTest
    static void anEmptyCatalogueIsAnEmptyPageRatherThanAFailure() {
        // No products at all: a new org should not make the app error.
        Test.startTest();
        abc_ApiModels.ProductListDto page = abc_ProductService.listProducts(query());
        Test.stopTest();

        Assert.areEqual(0, page.items.size());
        Assert.areEqual(0, page.count);
    }

    @IsTest
    static void theStandardPricebookIdIsResolvedAndCachedForTheTransaction() {
        Id first = abc_ProductService.standardPricebookId();
        Id second = abc_ProductService.standardPricebookId();

        Assert.isNotNull(first, 'The standard price book is what the catalogue prices from.');
        Assert.areEqual(first, second, 'It should be resolved once and reused.');
    }
}
