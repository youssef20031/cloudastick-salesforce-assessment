/**
 * Tests for abc_CartService - creating a cart, reading it, adding products and
 * checking out.
 *
 * A cart is a Draft Order, so most of what is worth testing is the boundary
 * between the API's idea of a cart and the platform's idea of an order: an
 * order cannot take line items until it exists as a Draft with a price book, it
 * freezes once activated, and every quantity has to survive both the API's own
 * rules and the order object's.
 *
 * Each failure case asserts the error code, not just that something threw. The
 * codes are a published contract with the Ionic developers, so a silent change
 * from 409 to 400 would be a breaking change for them.
 */
@IsTest
private class abc_CartServiceTest {
    private static List<Product2> products;
    private static List<PricebookEntry> entries;

    private static void seedCatalogue() {
        products = abc_TestDataFactory.createProducts(3);
        entries = abc_TestDataFactory.queryPricebookEntries(products);
    }

    /** A product with a deliberately small stock level, for the 409 path. */
    private static Product2 scarceProduct(Decimal stock) {
        Product2 scarce = abc_TestDataFactory.buildProduct(
            'Scarce Remedy',
            'ABC-SCARCE-1',
            abc_TestDataFactory.CATEGORY_MEDICINE,
            stock,
            false
        );
        insert scarce;
        abc_TestDataFactory.createPricebookEntry(scarce, 99);
        return scarce;
    }

    private static abc_ApiModels.CustomerRequest customer(String email, String first, String last) {
        abc_ApiModels.CustomerRequest request = new abc_ApiModels.CustomerRequest();
        request.email = email;
        request.firstName = first;
        request.lastName = last;
        return request;
    }

    private static abc_ApiModels.CreateCartRequest cartRequest(abc_ApiModels.CustomerRequest who) {
        abc_ApiModels.CreateCartRequest request = new abc_ApiModels.CreateCartRequest();
        request.customer = who;
        return request;
    }

    private static abc_ApiModels.CartItemRequest line(Id productId, Decimal quantity) {
        abc_ApiModels.CartItemRequest item = new abc_ApiModels.CartItemRequest();
        item.productId = productId;
        item.quantity = quantity;
        return item;
    }

    private static abc_ApiModels.AddItemRequest addRequest(Id productId, Decimal quantity) {
        abc_ApiModels.AddItemRequest request = new abc_ApiModels.AddItemRequest();
        request.productId = productId;
        request.quantity = quantity;
        return request;
    }

    /** Runs the callable and asserts it failed with exactly the expected code. */
    private static abc_ApiException expectFailure(String expectedCode, System.Callable work) {
        try {
            work.call('run', new Map<String, Object>());
            Assert.fail('Expected ' + expectedCode + ' but the call succeeded.');
        } catch (abc_ApiException e) {
            Assert.areEqual(expectedCode, e.errorCode, 'Wrong error code. Message was: ' + e.getMessage());
            return e;
        }
        return null;
    }

    // ------------------------------------------------------------ create

    @IsTest
    static void creatingACartOpensADraftOrderStampedAsComingFromTheApp() {
        seedCatalogue();

        Test.startTest();
        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'))
        );
        Test.stopTest();

        Assert.isNotNull(cart.cartId);
        Assert.areEqual(abc_CartService.STATUS_DRAFT, cart.status, 'A new cart is a Draft order.');
        Assert.isNotNull(cart.orderNumber, 'The order number is what a customer quotes.');
        Assert.areEqual(0, cart.items.size(), 'An empty request makes an empty cart.');
        Assert.areEqual(0, cart.totalAmount);
        Assert.isNotNull(cart.createdDate);

        Order stored = [
            SELECT Status, abc_Channel__c, Pricebook2Id, AccountId, BillToContactId
            FROM Order
            WHERE Id = :cart.cartId
        ];
        Assert.areEqual(abc_CartService.CHANNEL_IONIC, stored.abc_Channel__c, 'App traffic must be distinguishable.');
        Assert.isNotNull(stored.Pricebook2Id, 'Without a price book the cart could never take a line item.');
        Assert.areEqual(cart.customer.accountId, stored.AccountId);
        Assert.areEqual(cart.customer.contactId, stored.BillToContactId);
    }

    @IsTest
    static void anUnknownEmailCreatesTheAccountAndContactTogether() {
        seedCatalogue();

        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            cartRequest(customer('karim.adel@example.com', 'Karim', 'Adel'))
        );

        Contact created = [SELECT FirstName, LastName, Email, Account.Name FROM Contact WHERE Id = :cart.customer.contactId];
        Assert.areEqual('Karim', created.FirstName);
        Assert.areEqual('Adel', created.LastName);
        Assert.areEqual('karim.adel@example.com', created.Email);
        Assert.areEqual('Karim Adel', created.Account.Name, 'The account is named after the person.');
        Assert.areEqual('karim.adel@example.com', cart.customer.email);
    }

    @IsTest
    static void aKnownEmailReusesTheExistingCustomerInsteadOfDuplicatingThem() {
        seedCatalogue();
        Account existing = abc_TestDataFactory.createCustomer('Salma', 'Ibrahim', 'salma.ibrahim@example.com');
        Contact existingContact = abc_TestDataFactory.contactFor(existing.Id);

        Test.startTest();
        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            // Different name, same address: email is the identity.
            cartRequest(customer('salma.ibrahim@example.com', 'Sally', 'Ibraheem'))
        );
        Test.stopTest();

        Assert.areEqual(existingContact.Id, cart.customer.contactId, 'The same person must not be created twice.');
        Assert.areEqual(existing.Id, cart.customer.accountId);
        Assert.areEqual(1, [SELECT Id FROM Contact WHERE Email = 'salma.ibrahim@example.com'].size());
    }

    @IsTest
    static void aCartCanBeCreatedWithItemsAlreadyInIt() {
        seedCatalogue();

        abc_ApiModels.CreateCartRequest request = cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'));
        request.items = new List<abc_ApiModels.CartItemRequest>{
            line(products[0].Id, 2),
            line(products[1].Id, 1)
        };

        Test.startTest();
        abc_ApiModels.CartDto cart = abc_CartService.createCart(request);
        Test.stopTest();

        Assert.areEqual(2, cart.items.size());
        Decimal expected = (entries[0].UnitPrice * 2) + (entries[1].UnitPrice * 1);
        Assert.areEqual(expected, cart.totalAmount, 'The cart total is the sum of its lines.');
        for (abc_ApiModels.CartItemDto item : cart.items) {
            Assert.isNotNull(item.itemId);
            Assert.isNotNull(item.productName);
            Assert.areEqual(item.unitPrice * item.quantity, item.totalPrice);
        }
    }

    @IsTest
    static void thesameProductTwiceInOneRequestBecomesOneLine() {
        seedCatalogue();

        abc_ApiModels.CreateCartRequest request = cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'));
        request.items = new List<abc_ApiModels.CartItemRequest>{
            line(products[0].Id, 2),
            line(products[0].Id, 3)
        };

        abc_ApiModels.CartDto cart = abc_CartService.createCart(request);

        Assert.areEqual(1, cart.items.size(), 'A cart holds one line per product.');
        Assert.areEqual(5, cart.items[0].quantity, 'The quantities are added together.');
    }

    @IsTest
    static void createRejectsAMissingOrUnusableCustomer() {
        seedCatalogue();

        expectFailure(abc_ApiException.CODE_INVALID_INPUT, new Invoker(new CreateCall(null)));
        expectFailure(abc_ApiException.CODE_INVALID_INPUT, new Invoker(new CreateCall(cartRequest(null))));

        abc_ApiException noEmail = expectFailure(
            abc_ApiException.CODE_INVALID_INPUT,
            new Invoker(new CreateCall(cartRequest(customer('  ', 'Mona', 'Hassan'))))
        );
        Assert.areEqual('customer.email', noEmail.errorField);

        abc_ApiException badEmail = expectFailure(
            abc_ApiException.CODE_INVALID_INPUT,
            new Invoker(new CreateCall(cartRequest(customer('not-an-email', 'Mona', 'Hassan'))))
        );
        Assert.areEqual('customer.email', badEmail.errorField);

        abc_ApiException noLastName = expectFailure(
            abc_ApiException.CODE_INVALID_INPUT,
            new Invoker(new CreateCall(cartRequest(customer('mona.hassan@example.com', 'Mona', '   '))))
        );
        Assert.areEqual('customer.lastName', noLastName.errorField);
    }

    @IsTest
    static void createRejectsAnUnsellableProduct() {
        seedCatalogue();
        Product2 withdrawn = abc_TestDataFactory.buildProduct(
            'Withdrawn',
            'ABC-GONE-1',
            abc_TestDataFactory.CATEGORY_MEDICINE,
            10,
            false
        );
        withdrawn.IsActive = false;
        insert withdrawn;

        abc_ApiModels.CreateCartRequest request = cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'));
        request.items = new List<abc_ApiModels.CartItemRequest>{ line(withdrawn.Id, 1) };

        expectFailure(abc_ApiException.CODE_PRODUCT_NOT_FOUND, new Invoker(new CreateCall(request)));
    }

    // -------------------------------------------------------------- read

    @IsTest
    static void aCartCanBeReadBackById() {
        seedCatalogue();
        abc_ApiModels.CartDto created = abc_CartService.createCart(
            cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'))
        );

        abc_ApiModels.CartDto fetched = abc_CartService.getCart(created.cartId);

        Assert.areEqual(created.cartId, fetched.cartId);
        Assert.areEqual(created.orderNumber, fetched.orderNumber);
    }

    @IsTest
    static void everyUnusableCartIdIsA404() {
        seedCatalogue();

        expectFailure(abc_ApiException.CODE_CART_NOT_FOUND, new Invoker(new GetCall(null)));
        expectFailure(abc_ApiException.CODE_CART_NOT_FOUND, new Invoker(new GetCall('   ')));
        expectFailure(abc_ApiException.CODE_CART_NOT_FOUND, new Invoker(new GetCall('not-an-id')));
        // A well-formed id, but of the wrong object.
        expectFailure(abc_ApiException.CODE_CART_NOT_FOUND, new Invoker(new GetCall(UserInfo.getUserId())));
        // Well-formed Order id that does not exist.
        expectFailure(abc_ApiException.CODE_CART_NOT_FOUND, new Invoker(new GetCall('801000000000001AAA')));
    }

    // ---------------------------------------------------------- add item

    @IsTest
    static void addingAProductPutsANewLineInTheCart() {
        seedCatalogue();
        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'))
        );

        Test.startTest();
        abc_ApiModels.CartDto updated = abc_CartService.addItem(cart.cartId, addRequest(products[0].Id, 3));
        Test.stopTest();

        Assert.areEqual(1, updated.items.size());
        Assert.areEqual(3, updated.items[0].quantity);
        Assert.areEqual(products[0].Id, updated.items[0].productId);
        Assert.areEqual(entries[0].UnitPrice * 3, updated.totalAmount);
    }

    @IsTest
    static void addingAProductAlreadyInTheCartRaisesTheExistingLine() {
        seedCatalogue();
        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'))
        );
        abc_CartService.addItem(cart.cartId, addRequest(products[0].Id, 2));

        Test.startTest();
        abc_ApiModels.CartDto merged = abc_CartService.addItem(cart.cartId, addRequest(products[0].Id, 3));
        Test.stopTest();

        Assert.areEqual(1, merged.items.size(), 'The cart must not grow a second line for the same product.');
        Assert.areEqual(5, merged.items[0].quantity, 'Quantities are merged.');
    }

    @IsTest
    static void addItemRejectsQuantitiesTheWarehouseCouldNotHonour() {
        seedCatalogue();
        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'))
        );
        String cartId = cart.cartId;

        expectFailure(abc_ApiException.CODE_INVALID_INPUT, new Invoker(new AddCall(cartId, null)));

        abc_ApiException noQuantity = expectFailure(
            abc_ApiException.CODE_INVALID_INPUT,
            new Invoker(new AddCall(cartId, addRequest(products[0].Id, null)))
        );
        Assert.areEqual('quantity', noQuantity.errorField);

        expectFailure(
            abc_ApiException.CODE_VALIDATION_ERROR,
            new Invoker(new AddCall(cartId, addRequest(products[0].Id, 0)))
        );
        expectFailure(
            abc_ApiException.CODE_VALIDATION_ERROR,
            new Invoker(new AddCall(cartId, addRequest(products[0].Id, -2)))
        );
        expectFailure(
            abc_ApiException.CODE_VALIDATION_ERROR,
            new Invoker(new AddCall(cartId, addRequest(products[0].Id, 1.5)))
        );
        expectFailure(
            abc_ApiException.CODE_VALIDATION_ERROR,
            new Invoker(new AddCall(cartId, addRequest(products[0].Id, 100000)))
        );
    }

    @IsTest
    static void addItemRejectsAnUnknownProduct() {
        seedCatalogue();
        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'))
        );

        expectFailure(
            abc_ApiException.CODE_INVALID_INPUT,
            new Invoker(new AddCall(cart.cartId, addRequest(null, 1)))
        );
        expectFailure(
            abc_ApiException.CODE_PRODUCT_NOT_FOUND,
            new Invoker(new AddCall(cart.cartId, addRequest('01t000000000000AAA', 1)))
        );
    }

    @IsTest
    static void aCartCannotHoldMoreUnitsThanTheWarehouseHas() {
        seedCatalogue();
        Product2 scarce = scarceProduct(5);
        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'))
        );

        Test.startTest();
        abc_ApiException tooMany = expectFailure(
            abc_ApiException.CODE_INSUFFICIENT_STOCK,
            new Invoker(new AddCall(cart.cartId, addRequest(scarce.Id, 6)))
        );
        Test.stopTest();

        Assert.isTrue(tooMany.getMessage().contains('5'), 'The message should say what is actually available.');
        Assert.areEqual(0, abc_CartService.getCart(cart.cartId).items.size(), 'Nothing should have been added.');
    }

    @IsTest
    static void theStockCheckCountsWhatIsAlreadyInTheCart() {
        seedCatalogue();
        Product2 scarce = scarceProduct(5);
        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'))
        );
        abc_CartService.addItem(cart.cartId, addRequest(scarce.Id, 4));

        // 4 already held plus 2 more is 6, which is one more than exists.
        expectFailure(
            abc_ApiException.CODE_INSUFFICIENT_STOCK,
            new Invoker(new AddCall(cart.cartId, addRequest(scarce.Id, 2)))
        );

        // Exactly the remaining unit is fine.
        abc_ApiModels.CartDto filled = abc_CartService.addItem(cart.cartId, addRequest(scarce.Id, 1));
        Assert.areEqual(5, filled.items[0].quantity, 'A cart may hold the entire remaining stock.');
    }

    @IsTest
    static void aCartThatHasLeftDraftIsFrozen() {
        seedCatalogue();
        abc_ApiModels.CreateCartRequest request = cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'));
        request.items = new List<abc_ApiModels.CartItemRequest>{ line(products[0].Id, 1) };
        abc_ApiModels.CartDto cart = abc_CartService.createCart(request);
        abc_CartService.checkout(cart.cartId);

        Test.startTest();
        expectFailure(
            abc_ApiException.CODE_CART_NOT_EDITABLE,
            new Invoker(new AddCall(cart.cartId, addRequest(products[1].Id, 1)))
        );
        Test.stopTest();
    }

    // ---------------------------------------------------------- checkout

    @IsTest
    static void checkoutActivatesTheSameOrderRatherThanCopyingIt() {
        seedCatalogue();
        abc_ApiModels.CreateCartRequest request = cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'));
        request.items = new List<abc_ApiModels.CartItemRequest>{ line(products[0].Id, 2) };
        abc_ApiModels.CartDto cart = abc_CartService.createCart(request);

        Test.startTest();
        abc_ApiModels.CartDto placed = abc_CartService.checkout(cart.cartId);
        Test.stopTest();

        Assert.areEqual(cart.cartId, placed.cartId, 'Checkout must not create a second record.');
        Assert.areEqual(abc_CartService.STATUS_ACTIVATED, placed.status);
        Assert.areEqual(1, [SELECT Id FROM Order].size(), 'There is one order, not a cart and an order.');

        Order stored = [SELECT Status, StatusCode, abc_Order_Date__c, EffectiveDate FROM Order WHERE Id = :cart.cartId];
        Assert.areEqual('Activated', stored.StatusCode, 'The custom status must map to an Activated status code.');
        Assert.areEqual(Date.today(), stored.abc_Order_Date__c, 'Checkout is when the order was placed.');
    }

    @IsTest
    static void anEmptyCartCannotBeCheckedOut() {
        seedCatalogue();
        abc_ApiModels.CartDto cart = abc_CartService.createCart(
            cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'))
        );

        abc_ApiException empty = expectFailure(
            abc_ApiException.CODE_VALIDATION_ERROR,
            new Invoker(new CheckoutCall(cart.cartId))
        );
        Assert.areEqual('items', empty.errorField);
    }

    @IsTest
    static void checkingOutTwiceIsRejectedRatherThanReprocessed() {
        seedCatalogue();
        abc_ApiModels.CreateCartRequest request = cartRequest(customer('mona.hassan@example.com', 'Mona', 'Hassan'));
        request.items = new List<abc_ApiModels.CartItemRequest>{ line(products[0].Id, 1) };
        abc_ApiModels.CartDto cart = abc_CartService.createCart(request);
        abc_CartService.checkout(cart.cartId);

        expectFailure(abc_ApiException.CODE_CART_NOT_EDITABLE, new Invoker(new CheckoutCall(cart.cartId)));
    }

    @IsTest
    static void checkoutPullsForwardAnEffectiveDateLeftInThePast() {
        seedCatalogue();
        Account account = abc_TestDataFactory.createCustomer('Mona', 'Hassan', 'mona.hassan@example.com');
        Contact contact = abc_TestDataFactory.contactFor(account.Id);
        // A cart opened days ago and only now checked out: the validation rule
        // forbids an effective date earlier than the order date.
        Order stale = abc_TestDataFactory.createDraftOrder(
            account.Id,
            contact.Id,
            Date.today().addDays(-10),
            abc_TestDataFactory.CHANNEL_IONIC
        );
        abc_TestDataFactory.addItem(stale.Id, entries[0], 1);

        Test.startTest();
        abc_ApiModels.CartDto placed = abc_CartService.checkout(stale.Id);
        Test.stopTest();

        Assert.areEqual(abc_CartService.STATUS_ACTIVATED, placed.status);
        Order stored = [SELECT EffectiveDate, abc_Order_Date__c FROM Order WHERE Id = :stale.Id];
        Assert.areEqual(Date.today(), stored.EffectiveDate, 'The effective date is pulled forward to today.');
        Assert.areEqual(Date.today(), stored.abc_Order_Date__c);
    }

    // ---------------------------------------------------------------------
    // Small command objects so expectFailure can run any call uniformly.
    // Apex has no lambdas; System.Callable is the closest thing.
    // ---------------------------------------------------------------------

    private interface Command {
        void run();
    }

    private class Invoker implements System.Callable {
        private final Command command;
        Invoker(Command command) {
            this.command = command;
        }
        public Object call(String action, Map<String, Object> args) {
            command.run();
            return null;
        }
    }

    private class CreateCall implements Command {
        private final abc_ApiModels.CreateCartRequest request;
        CreateCall(abc_ApiModels.CreateCartRequest request) {
            this.request = request;
        }
        public void run() {
            abc_CartService.createCart(request);
        }
    }

    private class GetCall implements Command {
        private final String cartId;
        GetCall(String cartId) {
            this.cartId = cartId;
        }
        public void run() {
            abc_CartService.getCart(cartId);
        }
    }

    private class AddCall implements Command {
        private final String cartId;
        private final abc_ApiModels.AddItemRequest request;
        AddCall(String cartId, abc_ApiModels.AddItemRequest request) {
            this.cartId = cartId;
            this.request = request;
        }
        public void run() {
            abc_CartService.addItem(cartId, request);
        }
    }

    private class CheckoutCall implements Command {
        private final String cartId;
        CheckoutCall(String cartId) {
            this.cartId = cartId;
        }
        public void run() {
            abc_CartService.checkout(cartId);
        }
    }
}
