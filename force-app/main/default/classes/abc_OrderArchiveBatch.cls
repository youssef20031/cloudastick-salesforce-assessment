/**
 * Archives delivered orders that are more than a year old.
 *
 * Requirement: "for any order that has a status 'Delivered' and the 'Order Date'
 * is more than a year old, the order should be archived in a big object."
 *
 * Each qualifying Order becomes exactly one abc_Order_Archive__b row. Big
 * objects support neither master-detail nor lookup relationships, so the order's
 * line items travel inside the row as JSON (abc_Line_Items_JSON__c). One row per
 * order also makes the write atomic and idempotent: the row is keyed by the
 * index (abc_Order_Date__c, abc_Order_Number__c), so re-running the job
 * overwrites rather than duplicates.
 *
 * execute() does its work in a fixed order, and the order is not cosmetic:
 *
 *   1. archive  - Database.insertImmediate is treated as a callout. It must
 *                 happen before any sObject DML or EventBus.publish in the same
 *                 transaction, or the transaction dies with "uncommitted work
 *                 pending". So the archive write comes first, always.
 *   2. deactivate + delete - 'Delivered' is an Activated-coded status, and an
 *                 activated Order cannot be deleted. Status has to go back to a
 *                 Draft-coded value first, hence the update to 'Draft' before
 *                 the delete. Only orders whose archive row was actually written
 *                 are touched; a failed archive leaves its order exactly where
 *                 it was.
 *   3. abc_Logger.flush() - last, because flushing publishes platform events,
 *                 which counts as the DML that step 1 must precede.
 *
 * The big object write goes through abc_IOrderArchiver rather than being called
 * inline, because big object DML in a test is not rolled back and cannot be
 * mixed with sObject DML. Tests inject abc_FakeOrderArchiver; production uses
 * the no-arg constructor, which wires up abc_BigObjectOrderArchiver.
 *
 * Scheduled nightly at 02:00 by abc_OrderArchiveScheduler.
 */
public with sharing class abc_OrderArchiveBatch implements Database.Batchable<SObject>, Database.Stateful {
    private static final String CLASS_NAME = 'abc_OrderArchiveBatch';

    /** Orders per execute() call. */
    public static final Integer SCOPE_SIZE = 200;

    /** The only status that qualifies for archiving today. */
    public static final String STATUS_DELIVERED = 'Delivered';

    /** Draft-coded status an order must be returned to before it can be deleted. */
    public static final String STATUS_DRAFT = 'Draft';

    /** An order is archivable once its order date is this many years old. */
    public static final Integer ARCHIVE_AFTER_YEARS = 1;

    // abc_Order_Archive__b field lengths. Values are truncated rather than
    // losing the whole row to a STRING_TOO_LONG error.
    private static final Integer LEN_ID = 18;
    private static final Integer LEN_ORDER_NUMBER = 30;
    private static final Integer LEN_ACCOUNT_NAME = 255;
    private static final Integer LEN_STATUS = 40;
    private static final Integer LEN_CHANNEL = 40;
    private static final Integer LEN_LINE_ITEMS_JSON = 131072;

    private static final Time MIDNIGHT = Time.newInstance(0, 0, 0, 0);

    // Database.Stateful: these survive from one chunk to the next so finish()
    // can report on the whole run.
    public Integer recordsFound = 0;
    public Integer recordsArchived = 0;
    public Integer recordsDeleted = 0;
    public Integer recordsFailed = 0;

    @TestVisible
    private abc_IOrderArchiver archiver;

    /** Production entry point: writes to the real big object. */
    public abc_OrderArchiveBatch() {
        this(null);
    }

    /**
     * Test entry point: writes through the supplied archiver, so execute() can
     * be exercised without ever touching the big object.
     */
    public abc_OrderArchiveBatch(abc_IOrderArchiver archiver) {
        this.archiver = archiver == null ? new abc_BigObjectOrderArchiver() : archiver;
    }

    /** Orders placed strictly before this date are old enough to archive. */
    public static Date cutoffDate() {
        return Date.today().addYears(-ARCHIVE_AFTER_YEARS);
    }

    // ------------------------------------------------------------------ start

    public Database.QueryLocator start(Database.BatchableContext bc) {
        abc_Logger.setSource(abc_Logger.SOURCE_BATCH);
        Date cutoff = cutoffDate();
        return Database.getQueryLocator([
            SELECT
                Id,
                OrderNumber,
                Status,
                EffectiveDate,
                TotalAmount,
                AccountId,
                Account.Name,
                abc_Order_Date__c,
                abc_Delivered_Date__c,
                abc_Channel__c,
                (SELECT Id, Quantity, UnitPrice, TotalPrice, Product2.Name, Product2.ProductCode FROM OrderItems)
            FROM Order
            WHERE Status = 'Delivered' AND abc_Order_Date__c < :cutoff
        ]);
    }

    // ---------------------------------------------------------------- execute

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        abc_Logger.setSource(abc_Logger.SOURCE_BATCH);

        List<Order> orders = (List<Order>) scope;
        if (orders == null || orders.isEmpty()) {
            return;
        }
        recordsFound += orders.size();

        Datetime archivedOn = System.now();
        List<abc_Order_Archive__b> rows = new List<abc_Order_Archive__b>();
        for (Order order : orders) {
            rows.add(toArchiveRow(order, archivedOn));
        }

        // ---- step 1: the big object write, before any sObject DML.
        List<Database.SaveResult> results;
        try {
            results = archiver.archive(rows);
        } catch (Exception e) {
            recordsFailed += orders.size();
            abc_Logger.error(
                CLASS_NAME,
                'execute',
                'Archive write threw for ' + orders.size() + ' order(s). They stay in place and will be retried.',
                e
            );
            abc_Logger.flush();
            return;
        }

        if (results == null || results.size() != rows.size()) {
            recordsFailed += orders.size();
            abc_Logger.error(
                CLASS_NAME,
                'execute',
                'Archiver returned ' +
                    (results == null ? 'null' : String.valueOf(results.size())) +
                    ' result(s) for ' +
                    rows.size() +
                    ' row(s); cannot tell which orders were archived, so none are deleted.'
            );
            abc_Logger.flush();
            return;
        }

        List<Order> archived = new List<Order>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                archived.add(orders[i]);
                recordsArchived++;
            } else {
                recordsFailed++;
                abc_Logger.error(
                    CLASS_NAME,
                    'execute',
                    'Could not archive order ' + orders[i].OrderNumber + ': ' + describeErrors(results[i].getErrors()),
                    null,
                    orders[i].Id
                );
            }
        }

        // ---- step 2: only now may sObject DML happen.
        if (!archived.isEmpty()) {
            try {
                deactivateAndDelete(archived);
            } catch (Exception e) {
                recordsFailed += archived.size();
                abc_Logger.error(
                    CLASS_NAME,
                    'execute',
                    'Archived ' +
                        archived.size() +
                        ' order(s) but could not remove them from Order. The archive is keyed on ' +
                        'order date and number, so the next run overwrites the same rows rather than duplicating them.',
                    e
                );
            }
        }

        // ---- step 3: publishing the log events is DML, so it goes last.
        abc_Logger.flush();
    }

    // ----------------------------------------------------------------- finish

    public void finish(Database.BatchableContext bc) {
        abc_Logger.setSource(abc_Logger.SOURCE_BATCH);
        abc_Logger.info(
            CLASS_NAME,
            'finish',
            'Order archival finished' +
                (bc == null ? '' : ' (job ' + bc.getJobId() + ')') +
                '. Cutoff: order date before ' +
                cutoffDate().format() +
                '. Records found: ' +
                recordsFound +
                ', archived: ' +
                recordsArchived +
                ', deleted: ' +
                recordsDeleted +
                ', failed: ' +
                recordsFailed +
                '.'
        );
        abc_Logger.flush();
    }

    // ----------------------------------------------------------------- mapping

    /** One Order (plus its items) becomes one archive row. */
    private abc_Order_Archive__b toArchiveRow(Order order, Datetime archivedOn) {
        return new abc_Order_Archive__b(
            abc_Order_Date__c = toDatetime(order.abc_Order_Date__c),
            abc_Order_Number__c = truncate(order.OrderNumber, LEN_ORDER_NUMBER),
            abc_Order_Id__c = truncate(order.Id, LEN_ID),
            abc_Account_Id__c = truncate(order.AccountId, LEN_ID),
            abc_Account_Name__c = truncate(order.Account == null ? null : order.Account.Name, LEN_ACCOUNT_NAME),
            abc_Status__c = truncate(order.Status, LEN_STATUS),
            abc_Channel__c = truncate(order.abc_Channel__c, LEN_CHANNEL),
            abc_Effective_Date__c = toDatetime(order.EffectiveDate),
            abc_Delivered_Date__c = toDatetime(order.abc_Delivered_Date__c),
            abc_Total_Amount__c = order.TotalAmount,
            abc_Archived_On__c = archivedOn,
            abc_Line_Items_JSON__c = truncate(serializeItems(order), LEN_LINE_ITEMS_JSON)
        );
    }

    /**
     * The order's line items as a JSON array of
     * {productName, productCode, quantity, unitPrice, totalPrice}.
     */
    @TestVisible
    private static String serializeItems(Order order) {
        List<LineItem> items = new List<LineItem>();
        if (order.OrderItems != null) {
            for (OrderItem item : order.OrderItems) {
                items.add(new LineItem(item));
            }
        }
        return JSON.serialize(items);
    }

    /**
     * Big objects have no Date type, so every Date on the Order is stored as a
     * DateTime at midnight.
     */
    @TestVisible
    private static Datetime toDatetime(Date value) {
        return value == null ? null : Datetime.newInstance(value, MIDNIGHT);
    }

    // ------------------------------------------------------------------- DML

    /**
     * 'Delivered' maps to StatusCode Activated and an activated order cannot be
     * deleted, so the status goes back to Draft first. Both steps run with
     * allOrNone = false: one stubborn order must not strand the other 199.
     */
    private void deactivateAndDelete(List<Order> archived) {
        List<Order> toDeactivate = new List<Order>();
        for (Order order : archived) {
            toDeactivate.add(new Order(Id = order.Id, Status = STATUS_DRAFT));
        }

        List<Order> deletable = new List<Order>();
        List<Database.SaveResult> updates = Database.update(toDeactivate, false);
        for (Integer i = 0; i < updates.size(); i++) {
            if (updates[i].isSuccess()) {
                deletable.add(archived[i]);
            } else {
                recordFailure(archived[i], 'set back to Draft, so it was not deleted', updates[i].getErrors());
            }
        }

        if (deletable.isEmpty()) {
            return;
        }

        List<Database.DeleteResult> deletes = Database.delete(deletable, false);
        for (Integer i = 0; i < deletes.size(); i++) {
            if (deletes[i].isSuccess()) {
                recordsDeleted++;
            } else {
                recordFailure(deletable[i], 'deleted', deletes[i].getErrors());
            }
        }
    }

    /** One archived-but-not-removed order: counted and logged, never rethrown. */
    private void recordFailure(Order order, String whatFailed, List<Database.Error> errors) {
        recordsFailed++;
        abc_Logger.error(
            CLASS_NAME,
            'deactivateAndDelete',
            'Order ' + order.OrderNumber + ' was archived but could not be ' + whatFailed + ': ' + describeErrors(errors),
            null,
            order.Id
        );
    }

    // ---------------------------------------------------------------- helpers

    private static String describeErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'no error detail returned';
        }
        List<String> parts = new List<String>();
        for (Database.Error error : errors) {
            parts.add(error.getStatusCode() + ': ' + error.getMessage());
        }
        return String.join(parts, '; ');
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }

    /**
     * One archived order line. This is the shape stored in
     * abc_Line_Items_JSON__c, and the shape anything reading the archive should
     * deserialize back into.
     */
    public class LineItem {
        public String productName;
        public String productCode;
        public Decimal quantity;
        public Decimal unitPrice;
        public Decimal totalPrice;

        public LineItem() {
            // Required by JSON.deserialize.
        }

        public LineItem(OrderItem item) {
            this.productName = item.Product2 == null ? null : item.Product2.Name;
            this.productCode = item.Product2 == null ? null : item.Product2.ProductCode;
            this.quantity = item.Quantity;
            this.unitPrice = item.UnitPrice;
            this.totalPrice = item.TotalPrice;
        }
    }
}
