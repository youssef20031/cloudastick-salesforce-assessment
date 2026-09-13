/**
 * The production abc_IOrderArchiver: writes archive rows to the
 * abc_Order_Archive__b big object.
 *
 * Big objects accept only Database.insertImmediate(). Two consequences shape
 * how the batch uses this class:
 *
 *  1. insertImmediate is treated like a callout, so it must run before any
 *     sObject DML or EventBus.publish in the same transaction - otherwise the
 *     platform raises "You have uncommitted work pending". abc_OrderArchiveBatch
 *     therefore archives first, then deactivates and deletes the orders, and
 *     flushes the log last.
 *
 *  2. The write is an upsert on the index (abc_Order_Date__c, abc_Order_Number__c),
 *     not an insert. Re-running the batch over an order that was already
 *     archived overwrites the same row instead of duplicating it, which is what
 *     makes the job safely repeatable.
 */
public with sharing class abc_BigObjectOrderArchiver implements abc_IOrderArchiver {
    /**
     * @param rows archive rows to write; null or empty is a no-op
     * @return one SaveResult per row, in the order the rows were supplied
     */
    public List<Database.SaveResult> archive(List<abc_Order_Archive__b> rows) {
        if (rows == null || rows.isEmpty()) {
            return new List<Database.SaveResult>();
        }
        return Database.insertImmediate(rows);
    }
}
