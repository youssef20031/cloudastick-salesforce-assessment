/**
 * Tests for the warehouse orders console controller.
 *
 * The interesting behaviour is the icon precedence, because the four rules in
 * the assessment overlap. Every one of the four outcomes is asserted here, and
 * two of them are asserted specifically as precedence: a Delivered order that
 * was created today still shows the check mark, and an "In delivery" order that
 * was created days ago still shows the truck. Status beats date, both ways.
 *
 * Backdating uses abc_TestDataFactory.backdateCreation, which wraps
 * Test.setCreatedDate - the only way to obtain an order that was "created in
 * the past" inside a test.
 *
 * The last test proves least privilege: a Standard User holding nothing but the
 * abc_Warehouse_User permission set can open the console and read the orders.
 * Test users do not consume a licence, so this runs happily in a Developer
 * Edition org with only two Salesforce licences.
 */
@IsTest
private class abc_WarehouseOrdersControllerTest {
    /** Thrown on demand so the controller's catch block can be exercised. */
    private class abc_SimulatedFailureException extends Exception {
    }

    private static List<PricebookEntry> entries;
    private static Account customer;
    private static Contact buyer;

    /** Products priced 10, 20, 30 ... and one customer to hang the orders on. */
    private static void seedCatalogue(Integer productCount) {
        List<Product2> products = abc_TestDataFactory.createProducts(productCount);
        entries = abc_TestDataFactory.queryPricebookEntries(products);
        customer = abc_TestDataFactory.createCustomer('Warehouse', 'Customer', 'warehouse.customer@abc-pharmacy-test.example.com');
        buyer = abc_TestDataFactory.contactFor(customer.Id);
    }

    private static Order createOrder(String status, Date orderDate, List<Integer> quantities) {
        List<PricebookEntry> used = new List<PricebookEntry>();
        for (Integer i = 0; i < quantities.size(); i++) {
            used.add(entries[i]);
        }
        return abc_TestDataFactory.createOrderWithItems(customer.Id, buyer.Id, used, quantities, status, orderDate);
    }

    private static abc_WarehouseOrdersController.OrderRow rowFor(
        List<abc_WarehouseOrdersController.OrderRow> rows,
        Id orderId
    ) {
        for (abc_WarehouseOrdersController.OrderRow row : rows) {
            if (row.orderRecord.Id == orderId) {
                return row;
            }
        }
        return null;
    }

    // ------------------------------------------------------------ icon outcomes

    @IsTest
    static void createdTodayShowsHourglassStart() {
        seedCatalogue(2);
        Order draft = createOrder(abc_TestDataFactory.STATUS_DRAFT, Date.today(), new List<Integer>{ 2 });

        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.stopTest();

        abc_WarehouseOrdersController.OrderRow row = rowFor(controller.getRows(), draft.Id);
        Assert.isNotNull(row, 'The order created today should appear in the console.');
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_CREATED_TODAY,
            row.iconKey,
            'An order created today with no fulfilment status must use the hourglass-start icon.'
        );
        Assert.areEqual('&#x23F3;', row.iconEntity, 'Hourglass with flowing sand, as a numeric entity.');
        Assert.areEqual('Created today', row.iconLabel, 'The icon must carry a readable label as well.');
    }

    @IsTest
    static void createdInThePastShowsHourglassDone() {
        seedCatalogue(2);
        Order older = createOrder(abc_TestDataFactory.STATUS_ACTIVATED, Date.today().addDays(-40), new List<Integer>{ 1, 2 });
        abc_TestDataFactory.backdateCreation(older.Id, 40);

        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.stopTest();

        abc_WarehouseOrdersController.OrderRow row = rowFor(controller.getRows(), older.Id);
        Assert.isNotNull(row, 'The backdated order should still be listed.');
        Assert.isTrue(
            row.orderRecord.CreatedDate.date() < Date.today(),
            'backdateCreation should have moved CreatedDate before today.'
        );
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_CREATED_PAST,
            row.iconKey,
            'An Activated order created 40 days ago must use the hourglass-done icon.'
        );
        Assert.areEqual('&#x231B;', row.iconEntity, 'Hourglass done, as a numeric entity.');
        Assert.areEqual('Created before today', row.iconLabel, 'Readable label for the past-order icon.');
    }

    @IsTest
    static void inDeliveryShowsTruckEvenWhenCreatedInThePast() {
        seedCatalogue(2);
        Order shipping = createOrder(abc_TestDataFactory.STATUS_IN_DELIVERY, Date.today().addDays(-5), new List<Integer>{ 3 });
        abc_TestDataFactory.backdateCreation(shipping.Id, 5);

        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.stopTest();

        abc_WarehouseOrdersController.OrderRow row = rowFor(controller.getRows(), shipping.Id);
        Assert.isNotNull(row, 'The in-delivery order should be listed.');
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_IN_DELIVERY,
            row.iconKey,
            'Status beats date: an old "In delivery" order shows the truck, not the hourglass.'
        );
        Assert.areEqual('&#x1F69A;', row.iconEntity, 'Delivery truck, as a numeric entity.');
        Assert.areEqual('In delivery', row.iconLabel, 'Readable label for the truck icon.');
    }

    @IsTest
    static void deliveredShowsCheckMarkEvenWhenCreatedToday() {
        seedCatalogue(2);
        Order delivered = createOrder(abc_TestDataFactory.STATUS_DELIVERED, Date.today(), new List<Integer>{ 1, 1 });

        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.stopTest();

        abc_WarehouseOrdersController.OrderRow row = rowFor(controller.getRows(), delivered.Id);
        Assert.isNotNull(row, 'The delivered order should be listed.');
        Assert.areEqual(
            Date.today(),
            row.orderRecord.CreatedDate.date(),
            'This order really was created today, so both rules match it.'
        );
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_DELIVERED,
            row.iconKey,
            'Precedence: Delivered wins over "created today".'
        );
        Assert.areEqual('&#x2705;', row.iconEntity, 'White heavy check mark, as a numeric entity.');
        Assert.areEqual('Delivered', row.iconLabel, 'Readable label for the check-mark icon.');
    }

    @IsTest
    static void allFourIconsAppearTogether() {
        seedCatalogue(3);
        Order today = createOrder(abc_TestDataFactory.STATUS_DRAFT, Date.today(), new List<Integer>{ 1 });
        Order past = createOrder(abc_TestDataFactory.STATUS_ACTIVATED, Date.today().addDays(-30), new List<Integer>{ 1 });
        Order shipping = createOrder(abc_TestDataFactory.STATUS_IN_DELIVERY, Date.today().addDays(-3), new List<Integer>{ 2 });
        Order delivered = createOrder(abc_TestDataFactory.STATUS_DELIVERED, Date.today().addDays(-10), new List<Integer>{ 1 });
        abc_TestDataFactory.backdateCreation(past.Id, 30);
        abc_TestDataFactory.backdateCreation(shipping.Id, 3);
        abc_TestDataFactory.backdateCreation(delivered.Id, 10);

        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.stopTest();

        List<abc_WarehouseOrdersController.OrderRow> rows = controller.getRows();
        Assert.areEqual(4, rows.size(), 'All four orders belong on the page.');
        Assert.areEqual(4, controller.getOrderCount(), 'The header count must match the rows.');
        Assert.isTrue(controller.getHasOrders(), 'The page is not in its empty state.');
        Assert.isFalse(controller.getHasError(), 'Nothing failed, so no error banner.');
        Assert.isFalse(controller.getRowLimitReached(), 'Four orders is a long way below the 1000 cap.');

        Map<String, String> iconByOrderId = new Map<String, String>();
        Set<String> detailIds = new Set<String>();
        for (abc_WarehouseOrdersController.OrderRow row : rows) {
            iconByOrderId.put(row.orderRecord.Id, row.iconKey);
            detailIds.add(row.detailId);
        }

        Assert.areEqual(abc_WarehouseOrdersController.ICON_CREATED_TODAY, iconByOrderId.get(today.Id), 'Draft, today.');
        Assert.areEqual(abc_WarehouseOrdersController.ICON_CREATED_PAST, iconByOrderId.get(past.Id), 'Activated, 30 days old.');
        Assert.areEqual(abc_WarehouseOrdersController.ICON_IN_DELIVERY, iconByOrderId.get(shipping.Id), 'In delivery.');
        Assert.areEqual(abc_WarehouseOrdersController.ICON_DELIVERED, iconByOrderId.get(delivered.Id), 'Delivered.');
        Assert.areEqual(4, detailIds.size(), 'Each detail row needs its own DOM id for aria-controls.');

        // Newest first, so the page opens on the work that just came in.
        Assert.areEqual(today.Id, rows[0].orderRecord.Id, 'Rows are ordered by CreatedDate descending.');
    }

    // -------------------------------------------------------------- line items

    @IsTest
    static void lineItemsAreExposedPerOrderWithNameQuantityAndPrice() {
        seedCatalogue(3);
        Order order = createOrder(abc_TestDataFactory.STATUS_IN_DELIVERY, Date.today(), new List<Integer>{ 2, 1, 4 });

        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.stopTest();

        abc_WarehouseOrdersController.OrderRow row = rowFor(controller.getRows(), order.Id);
        Assert.isNotNull(row, 'The order should be listed.');
        Assert.isTrue(row.getHasItems(), 'The row reports that it has products to show.');
        Assert.areEqual(3, row.getItemCount(), 'Three product lines were ordered.');
        Assert.areEqual(3, row.items.size(), 'The items travel with the order, one query for the page.');

        // The subquery orders by product name, so the picking list reads alphabetically.
        Assert.areEqual('ABC Test Product 1', row.items[0].Product2.Name, 'Product name is exposed.');
        Assert.areEqual(2, Integer.valueOf(row.items[0].Quantity), 'Quantity is exposed.');
        Assert.areEqual(10, row.items[0].UnitPrice.intValue(), 'Unit price is exposed.');
        Assert.areEqual(20, row.items[0].TotalPrice.intValue(), 'Line total is 2 x 10.');

        Assert.areEqual('ABC Test Product 2', row.items[1].Product2.Name, 'Second line, alphabetical.');
        Assert.areEqual(1, Integer.valueOf(row.items[1].Quantity), 'Second line quantity.');
        Assert.areEqual(20, row.items[1].UnitPrice.intValue(), 'Second line unit price.');

        Assert.areEqual('ABC Test Product 3', row.items[2].Product2.Name, 'Third line, alphabetical.');
        Assert.areEqual(4, Integer.valueOf(row.items[2].Quantity), 'Third line quantity.');
        Assert.areEqual(30, row.items[2].UnitPrice.intValue(), 'Third line unit price.');

        Assert.isTrue(String.isNotBlank(row.getToggleLabel()), 'The expand button needs a spoken label.');
        Assert.isTrue(row.getToggleLabel().contains(row.orderNumber), 'The label names the order it opens.');
        Assert.isTrue(String.isNotBlank(row.effectiveDateText), 'The effective date is rendered as text.');
        Assert.isTrue(String.isNotBlank(row.createdDateText), 'The created date is rendered as text.');
        Assert.isTrue(String.isNotBlank(row.totalAmountText), 'The order total is rendered as text.');
        Assert.areEqual(customer.Name, row.accountName, 'The customer name is carried through the lookup.');
        Assert.areEqual(abc_TestDataFactory.STATUS_IN_DELIVERY, row.status, 'The status is shown as text, not only as an icon.');
    }

    @IsTest
    static void orderWithoutLineItemsStillRenders() {
        seedCatalogue(1);
        Order empty = abc_TestDataFactory.createDraftOrder(customer.Id, buyer.Id);

        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.stopTest();

        abc_WarehouseOrdersController.OrderRow row = rowFor(controller.getRows(), empty.Id);
        Assert.isNotNull(row, 'An order with no products is still an order.');
        Assert.isFalse(row.getHasItems(), 'The page shows the "no products yet" note for this row.');
        Assert.areEqual(0, row.getItemCount(), 'No line items.');
        Assert.isNotNull(row.items, 'An empty subquery must become an empty list, never null.');
        Assert.areEqual('0.00', row.totalAmountText, 'An order with nothing on it totals zero.');
    }

    // ------------------------------------------------------------- empty state

    @IsTest
    static void emptyStateIsCalmNotBroken() {
        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.stopTest();

        Assert.isFalse(controller.getHasOrders(), 'There are no orders at all.');
        Assert.areEqual(0, controller.getOrderCount(), 'Nothing to count.');
        Assert.areEqual(0, controller.getRows().size(), 'An empty list, not a null pointer.');
        Assert.isFalse(controller.getHasError(), 'An empty warehouse is not an error.');
        Assert.isFalse(controller.getRowLimitReached(), 'Zero rows is not the cap.');
        Assert.areEqual(1000, controller.getMaxRows(), 'apex:repeat renders at most 1000 items.');
        Assert.areEqual(1000, abc_WarehouseOrdersController.MAX_ROWS, 'The query LIMIT and the notice agree.');
    }

    // ------------------------------------------------------- icon rule in isolation

    @IsTest
    static void resolveIconKeyCoversEveryBranch() {
        Datetime now = System.now();
        Datetime lastWeek = System.now().addDays(-7);

        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_DELIVERED,
            abc_WarehouseOrdersController.resolveIconKey('Delivered', now),
            'Delivered first.'
        );
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_IN_DELIVERY,
            abc_WarehouseOrdersController.resolveIconKey('In delivery', now),
            'In delivery second.'
        );
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_CREATED_TODAY,
            abc_WarehouseOrdersController.resolveIconKey('Draft', now),
            'Created today third.'
        );
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_CREATED_PAST,
            abc_WarehouseOrdersController.resolveIconKey('Draft', lastWeek),
            'Otherwise, created earlier.'
        );
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_CREATED_PAST,
            abc_WarehouseOrdersController.resolveIconKey(null, null),
            'A missing status and a missing date must not throw.'
        );
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_DELIVERED,
            abc_WarehouseOrdersController.resolveIconKey('delivered', lastWeek),
            'Status matching is case-insensitive, so a relabelled picklist cannot silently break it.'
        );

        Assert.areEqual(
            '&#x2705;',
            abc_WarehouseOrdersController.iconEntityFor(abc_WarehouseOrdersController.ICON_DELIVERED),
            'Check mark entity.'
        );
        Assert.areEqual(
            '&#x231B;',
            abc_WarehouseOrdersController.iconEntityFor('something-unknown'),
            'An unknown key falls back to the neutral hourglass rather than rendering nothing.'
        );
        Assert.areEqual(
            'Created before today',
            abc_WarehouseOrdersController.iconLabelFor('something-unknown'),
            'The fallback label matches the fallback icon.'
        );
    }

    // --------------------------------------------------------- failure handling

    @IsTest
    static void queryFailureShowsAMessageAndIsLogged() {
        abc_WarehouseOrdersController.testInjectedFailure = new abc_SimulatedFailureException('Simulated SOQL failure');

        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.getEventBus().deliver();
        Test.stopTest();
        abc_WarehouseOrdersController.testInjectedFailure = null;

        Assert.isTrue(controller.getHasError(), 'The controller reports the failure.');
        Assert.areEqual(0, controller.getRows().size(), 'A failed query leaves an empty list, not half a page.');
        Assert.isTrue(
            controller.getErrorMessage().contains('could not be loaded'),
            'The user sees a sentence, never a stack trace.'
        );
        Assert.isFalse(
            controller.getErrorMessage().contains('Simulated SOQL failure'),
            'Internal detail stays in the log, out of the page.'
        );
        Assert.isTrue(ApexPages.hasMessages(ApexPages.Severity.ERROR), 'apex:pageMessages has something to render.');

        List<abc_Log__c> logs = [
            SELECT Id, abc_Level__c, abc_Source__c, abc_Class__c, abc_Method__c, abc_Message__c
            FROM abc_Log__c
            WHERE abc_Class__c = 'abc_WarehouseOrdersController'
        ];
        Assert.areEqual(1, logs.size(), 'The failure is logged exactly once.');
        Assert.areEqual('ERROR', logs[0].abc_Level__c, 'Logged at ERROR.');
        Assert.areEqual('Visualforce', logs[0].abc_Source__c, 'Tagged as coming from the Visualforce layer.');
        Assert.areEqual('load', logs[0].abc_Method__c, 'The log points at the method that failed.');
        Assert.isTrue(
            logs[0].abc_Message__c.contains('Simulated SOQL failure'),
            'The detail the page withheld is in the log.'
        );
    }

    @IsTest
    static void missingReadAccessShowsAPermissionMessage() {
        abc_WarehouseOrdersController.testForceNoAccess = true;

        Test.startTest();
        abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
        Test.getEventBus().deliver();
        Test.stopTest();
        abc_WarehouseOrdersController.testForceNoAccess = false;

        Assert.isTrue(controller.getHasError(), 'A permission problem is surfaced, not swallowed.');
        Assert.areEqual(0, controller.getRows().size(), 'Nothing is listed without read access.');
        Assert.isTrue(
            controller.getErrorMessage().contains('abc Warehouse User'),
            'The message tells the user exactly which permission set to ask for.'
        );
        Assert.isTrue(ApexPages.hasMessages(ApexPages.Severity.WARNING), 'Shown as a warning, not as a crash.');

        List<abc_Log__c> logs = [SELECT Id, abc_Level__c FROM abc_Log__c WHERE abc_Class__c = 'abc_WarehouseOrdersController'];
        Assert.areEqual(1, logs.size(), 'The denied access is recorded for the administrator.');
        Assert.areEqual('WARN', logs[0].abc_Level__c, 'A permission gap is a warning, not an error.');
    }

    // ------------------------------------------------------- least privilege

    /**
     * The warehouse operator is not an administrator. This runs the controller
     * as a Standard User whose only grant is the abc_Warehouse_User permission
     * set, and proves the console still lists the orders.
     *
     * The user is inserted inside System.runAs so that setup-object DML (User,
     * PermissionSetAssignment) and ordinary DML (Account, Order) can coexist in
     * one test transaction without a MIXED_DML_OPERATION.
     */
    @IsTest
    static void warehouseUserWithOnlyItsPermissionSetSeesTheOrders() {
        User warehouseUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            warehouseUser = abc_TestDataFactory.createUserWithPermissionSet('whse', 'abc_Warehouse_User');
        }

        seedCatalogue(2);
        Order delivered = createOrder(abc_TestDataFactory.STATUS_DELIVERED, Date.today(), new List<Integer>{ 2, 1 });
        Order draft = createOrder(abc_TestDataFactory.STATUS_DRAFT, Date.today(), new List<Integer>{ 1 });

        List<abc_WarehouseOrdersController.OrderRow> rows;
        Boolean sawError;
        System.runAs(warehouseUser) {
            Test.startTest();
            abc_WarehouseOrdersController controller = new abc_WarehouseOrdersController();
            rows = controller.getRows();
            sawError = controller.getHasError();
            Test.stopTest();
        }

        Assert.isFalse(sawError, 'The least-privileged warehouse user must not hit a permission error.');
        Assert.areEqual(2, rows.size(), 'Both orders are visible to the warehouse user.');

        abc_WarehouseOrdersController.OrderRow deliveredRow = rowFor(rows, delivered.Id);
        abc_WarehouseOrdersController.OrderRow draftRow = rowFor(rows, draft.Id);
        Assert.isNotNull(deliveredRow, 'The delivered order is readable.');
        Assert.isNotNull(draftRow, 'The draft order is readable.');
        Assert.areEqual(
            abc_WarehouseOrdersController.ICON_DELIVERED,
            deliveredRow.iconKey,
            'The icon rules behave identically for the warehouse user.'
        );
        Assert.areEqual(2, deliveredRow.getItemCount(), 'Line items are readable too, so rows can expand.');
        Assert.areEqual('ABC Test Product 1', deliveredRow.items[0].Product2.Name, 'Product names come through.');
    }
}
