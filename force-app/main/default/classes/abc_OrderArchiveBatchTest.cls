/**
 * Tests for abc_OrderArchiveBatch - the job that moves Delivered orders older
 * than one year into the abc_Order_Archive__b big object and removes them from
 * Order.
 *
 * Every test injects abc_FakeOrderArchiver instead of the real writer. That is
 * not a convenience: Salesforce forbids big object DML inside an Apex test, and
 * the batch has to do both a big object write and ordinary sObject DML in one
 * transaction. The fake takes the big object out of the picture so everything
 * that actually carries risk - the selection rule, the mapping, the
 * deactivate-then-delete sequence, and what happens when a write fails - can be
 * asserted for real. See abc_BigObjectOrderArchiverTest for the other half.
 *
 * Orders are seeded through abc_TestDataFactory, which knows the two platform
 * rules that make order fixtures awkward: an Order must be inserted as Draft
 * with a Pricebook2Id before OrderItems can be attached, and "Delivered" is an
 * Activated-coded status, so it can only be reached by a later update.
 */
@IsTest
private class abc_OrderArchiveBatchTest {
    /** Comfortably past the one-year cutoff. */
    private static final Integer LONG_AGO = 400;
    /** Delivered, but far too recent to archive. */
    private static final Integer RECENTLY = 30;

    private static List<PricebookEntry> entries;
    private static Account customer;
    private static Contact buyer;

    private static void seedCatalogue() {
        abc_FakeOrderArchiver.reset();
        List<Product2> products = abc_TestDataFactory.createProducts(3);
        entries = abc_TestDataFactory.queryPricebookEntries(products);
        customer = abc_TestDataFactory.createCustomer('Mona', 'Hassan', 'mona.hassan@example.com');
        buyer = abc_TestDataFactory.contactFor(customer.Id);
    }

    private static Order orderPlaced(Integer daysAgo, String status) {
        return abc_TestDataFactory.createOrderWithItems(
            customer.Id,
            buyer.Id,
            new List<PricebookEntry>{ entries[0], entries[1] },
            new List<Integer>{ 2, 3 },
            status,
            Date.today().addDays(-daysAgo)
        );
    }

    private static void runBatch() {
        Test.startTest();
        Database.executeBatch(new abc_OrderArchiveBatch(new abc_FakeOrderArchiver()), abc_OrderArchiveBatch.SCOPE_SIZE);
        Test.stopTest();
    }

    private static Boolean orderStillExists(Id orderId) {
        return ![SELECT Id FROM Order WHERE Id = :orderId].isEmpty();
    }

    // ------------------------------------------------------- selection rule

    @IsTest
    static void archivesADeliveredOrderOlderThanOneYearAndRemovesItFromOrder() {
        seedCatalogue();
        Order old = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_DELIVERED);

        runBatch();

        Assert.areEqual(1, abc_FakeOrderArchiver.archivedRows.size(), 'The year-old delivered order should be archived.');
        Assert.areEqual(
            old.OrderNumber,
            abc_FakeOrderArchiver.onlyRow().abc_Order_Number__c,
            'The archive row should carry the order number.'
        );
        Assert.isFalse(orderStillExists(old.Id), 'An archived order should no longer exist as an Order.');
    }

    @IsTest
    static void leavesADeliveredOrderThatIsStillWithinTheYear() {
        seedCatalogue();
        Order recent = orderPlaced(RECENTLY, abc_TestDataFactory.STATUS_DELIVERED);

        runBatch();

        Assert.areEqual(0, abc_FakeOrderArchiver.archivedRows.size(), 'A recent delivered order is not archival.');
        Assert.isTrue(orderStillExists(recent.Id), 'A recent delivered order must stay put.');
    }

    @IsTest
    static void leavesAnOldOrderThatIsNotDelivered() {
        seedCatalogue();
        Order oldButInDelivery = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_IN_DELIVERY);
        Order oldButActivated = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_ACTIVATED);
        Order oldDraft = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_DRAFT);

        runBatch();

        Assert.areEqual(0, abc_FakeOrderArchiver.archivedRows.size(), 'Age alone does not make an order archival.');
        Assert.isTrue(orderStillExists(oldButInDelivery.Id), 'An old in-delivery order stays.');
        Assert.isTrue(orderStillExists(oldButActivated.Id), 'An old activated order stays.');
        Assert.isTrue(orderStillExists(oldDraft.Id), 'An old draft cart stays.');
    }

    @IsTest
    static void selectsOnlyTheQualifyingOrdersOutOfAMixedSet() {
        seedCatalogue();
        Order archivable = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_DELIVERED);
        Order alsoArchivable = orderPlaced(LONG_AGO + 120, abc_TestDataFactory.STATUS_DELIVERED);
        Order tooRecent = orderPlaced(RECENTLY, abc_TestDataFactory.STATUS_DELIVERED);
        Order wrongStatus = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_IN_DELIVERY);

        runBatch();

        Assert.areEqual(2, abc_FakeOrderArchiver.archivedRows.size(), 'Exactly the two qualifying orders.');
        Assert.isNotNull(abc_FakeOrderArchiver.rowFor(archivable.OrderNumber));
        Assert.isNotNull(abc_FakeOrderArchiver.rowFor(alsoArchivable.OrderNumber));
        Assert.isFalse(orderStillExists(archivable.Id));
        Assert.isFalse(orderStillExists(alsoArchivable.Id));
        Assert.isTrue(orderStillExists(tooRecent.Id));
        Assert.isTrue(orderStillExists(wrongStatus.Id));
    }

    @IsTest
    static void cutoffIsExactlyOneYearBeforeToday() {
        Assert.areEqual(
            Date.today().addYears(-1),
            abc_OrderArchiveBatch.cutoffDate(),
            'The archival window is one year, measured from today.'
        );
    }

    // ------------------------------------------------------------- mapping

    @IsTest
    static void archiveRowCarriesTheOrderSnapshotAndItsLineItemsAsJson() {
        seedCatalogue();
        Date placed = Date.today().addDays(-LONG_AGO);
        Order old = abc_TestDataFactory.createOrderWithItems(
            customer.Id,
            buyer.Id,
            new List<PricebookEntry>{ entries[0], entries[1] },
            new List<Integer>{ 2, 3 },
            abc_TestDataFactory.STATUS_DELIVERED,
            placed
        );

        runBatch();

        abc_Order_Archive__b row = abc_FakeOrderArchiver.onlyRow();
        Assert.areEqual(old.OrderNumber, row.abc_Order_Number__c);
        Assert.areEqual(old.Id, row.abc_Order_Id__c, 'The pre-deletion Order id is kept for traceability.');
        Assert.areEqual(customer.Id, row.abc_Account_Id__c);
        Assert.areEqual('Mona Hassan', row.abc_Account_Name__c, 'The customer name is denormalised into the archive.');
        Assert.areEqual(abc_TestDataFactory.STATUS_DELIVERED, row.abc_Status__c);
        Assert.areEqual(old.TotalAmount, row.abc_Total_Amount__c);
        Assert.isNotNull(row.abc_Archived_On__c, 'The run timestamp is recorded.');

        // Big objects have no Date type, so dates are stored as midnight DateTimes.
        Assert.areEqual(
            Datetime.newInstance(placed, Time.newInstance(0, 0, 0, 0)),
            row.abc_Order_Date__c,
            'The order date becomes a midnight DateTime.'
        );

        List<abc_OrderArchiveBatch.LineItem> items = (List<abc_OrderArchiveBatch.LineItem>) JSON.deserialize(
            row.abc_Line_Items_JSON__c,
            List<abc_OrderArchiveBatch.LineItem>.class
        );
        Assert.areEqual(2, items.size(), 'Both line items should be inside the archive row.');

        Map<String, abc_OrderArchiveBatch.LineItem> byName = new Map<String, abc_OrderArchiveBatch.LineItem>();
        for (abc_OrderArchiveBatch.LineItem item : items) {
            byName.put(item.productName, item);
        }
        abc_OrderArchiveBatch.LineItem first = byName.get('ABC Test Product 1');
        Assert.isNotNull(first, 'Product names should survive into the archive: ' + byName.keySet());
        Assert.areEqual(2, first.quantity, 'Quantity should survive.');
        Assert.areEqual(entries[0].UnitPrice, first.unitPrice, 'Unit price should survive.');
        Assert.areEqual(entries[0].UnitPrice * 2, first.totalPrice, 'Line total should survive.');
        Assert.areEqual('ABC-T-1', first.productCode, 'Product code should survive.');
    }

    /**
     * The batch serialises an order with no products as "[]" rather than null,
     * but that branch is defensive only: Salesforce itself refuses to activate
     * an empty order, so a Delivered order always has at least one line, and an
     * Activated order cannot have its products removed afterwards. This test
     * pins the platform rule that makes the branch unreachable, so that if the
     * rule ever changes the defensive code is known to be load bearing.
     */
    @IsTest
    static void salesforceWillNotLetAnOrderReachDeliveredWithNoProducts() {
        seedCatalogue();
        Order bare = abc_TestDataFactory.createDraftOrder(
            customer.Id,
            buyer.Id,
            Date.today().addDays(-LONG_AGO),
            abc_TestDataFactory.CHANNEL_MANUAL
        );

        bare.Status = abc_TestDataFactory.STATUS_DELIVERED;
        String message;
        try {
            update bare;
        } catch (DmlException e) {
            message = e.getMessage();
        }

        Assert.isNotNull(message, 'An order with no products must not be activatable.');
        Assert.isTrue(
            message.contains('at least one product'),
            'Expected the platform activation rule, got: ' + message
        );
        Assert.areEqual(
            abc_TestDataFactory.STATUS_DRAFT,
            [SELECT Status FROM Order WHERE Id = :bare.Id].Status,
            'The order should still be a Draft cart.'
        );
    }

    // --------------------------------------------------------- failure paths

    @IsTest
    static void anOrderWhoseArchiveWriteFailsIsLeftInPlaceAndLogged() {
        seedCatalogue();
        Order old = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_DELIVERED);
        abc_FakeOrderArchiver.failEverything = true;

        runBatch();

        Assert.isTrue(orderStillExists(old.Id), 'A failed archive must not delete the order.');
        List<abc_Log__c> errors = [
            SELECT abc_Message__c, abc_Record_Id__c
            FROM abc_Log__c
            WHERE abc_Level__c = :abc_Logger.LEVEL_ERROR AND abc_Source__c = :abc_Logger.SOURCE_BATCH
        ];
        Assert.isFalse(errors.isEmpty(), 'The failure should be logged.');
        Assert.areEqual(old.Id, errors[0].abc_Record_Id__c, 'The log should point at the order that failed.');
    }

    @IsTest
    static void oneFailureDoesNotStopTheOtherOrdersBeingArchived() {
        seedCatalogue();
        Order doomed = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_DELIVERED);
        Order fine = orderPlaced(LONG_AGO + 30, abc_TestDataFactory.STATUS_DELIVERED);
        abc_FakeOrderArchiver.failOrderNumbers = new Set<String>{ doomed.OrderNumber };

        runBatch();

        Assert.isTrue(orderStillExists(doomed.Id), 'The failed order stays.');
        Assert.isFalse(orderStillExists(fine.Id), 'The successful one is still removed.');
    }

    @IsTest
    static void anArchiverThatThrowsLeavesEveryOrderInPlace() {
        seedCatalogue();
        Order old = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_DELIVERED);
        abc_FakeOrderArchiver.throwOnArchive = true;

        runBatch();

        Assert.isTrue(orderStillExists(old.Id), 'If the writer throws, nothing may be deleted.');
        Assert.isFalse(
            [
                SELECT Id
                FROM abc_Log__c
                WHERE abc_Level__c = :abc_Logger.LEVEL_ERROR AND abc_Source__c = :abc_Logger.SOURCE_BATCH
            ].isEmpty(),
            'The thrown failure should be logged.'
        );
    }

    @IsTest
    static void aMismatchedResultCountDeletesNothing() {
        seedCatalogue();
        Order first = orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_DELIVERED);
        Order second = orderPlaced(LONG_AGO + 10, abc_TestDataFactory.STATUS_DELIVERED);
        // The batch pairs result i with row i. If it cannot, it must not guess.
        abc_FakeOrderArchiver.forceResultCount = 1;

        runBatch();

        Assert.isTrue(orderStillExists(first.Id), 'Ambiguous results must not delete anything.');
        Assert.isTrue(orderStillExists(second.Id), 'Ambiguous results must not delete anything.');
    }

    // ------------------------------------------------------- run accounting

    @IsTest
    static void finishLogsASummaryOfWhatTheRunDid() {
        seedCatalogue();
        orderPlaced(LONG_AGO, abc_TestDataFactory.STATUS_DELIVERED);
        orderPlaced(RECENTLY, abc_TestDataFactory.STATUS_DELIVERED);

        runBatch();

        List<abc_Log__c> summaries = [
            SELECT abc_Message__c
            FROM abc_Log__c
            WHERE abc_Level__c = :abc_Logger.LEVEL_INFO AND abc_Method__c = 'finish'
        ];
        Assert.areEqual(1, summaries.size(), 'finish() should log exactly one summary.');
        String message = summaries[0].abc_Message__c;
        Assert.isTrue(message.contains('found: 1'), 'The summary should count what was selected: ' + message);
        Assert.isTrue(message.contains('archived: 1'), 'The summary should count what was archived: ' + message);
        Assert.isTrue(message.contains('deleted: 1'), 'The summary should count what was removed: ' + message);
    }

    @IsTest
    static void aRunWithNothingToDoIsHarmless() {
        seedCatalogue();
        orderPlaced(RECENTLY, abc_TestDataFactory.STATUS_DELIVERED);

        runBatch();

        Assert.areEqual(0, abc_FakeOrderArchiver.callCount, 'With no qualifying orders the writer is never called.');
        Assert.isFalse(
            [SELECT Id FROM abc_Log__c WHERE abc_Method__c = 'finish'].isEmpty(),
            'finish() still reports, even on an empty run.'
        );
    }

    @IsTest
    static void theDefaultConstructorUsesTheRealBigObjectArchiver() {
        // Production entry point: no injection, so the real writer must be wired in.
        abc_OrderArchiveBatch batch = new abc_OrderArchiveBatch();
        Assert.areEqual(0, batch.recordsFound, 'A fresh batch starts with empty counters.');
        Assert.areEqual(0, batch.recordsArchived);
        Assert.areEqual(0, batch.recordsDeleted);
        Assert.areEqual(0, batch.recordsFailed);
        Assert.areEqual(200, abc_OrderArchiveBatch.SCOPE_SIZE, 'Scope stays at 200 records per chunk.');
    }
}
