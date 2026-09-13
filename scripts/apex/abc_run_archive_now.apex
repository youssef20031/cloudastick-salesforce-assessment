/**
 * Runs the order archival batch immediately, against real data.
 *
 *   sf apex run --file scripts/apex/abc_run_archive_now.apex --target-org abcDev
 *
 * This is also the only way the real big object write is exercised: Salesforce
 * does not allow big object DML inside an Apex test, so abc_OrderArchiveBatch
 * is unit tested against a fake writer and proved for real here.
 *
 * Follow it with scripts/apex/abc_query_archive.apex to read the rows back.
 *
 * The batch archives every Order whose Status is "Delivered" and whose
 * abc_Order_Date__c is more than one year old. Archived orders are deleted from
 * Order, so run it deliberately.
 */
Date cutoff = abc_OrderArchiveBatch.cutoffDate();

List<Order> candidates = [
    SELECT OrderNumber, Status, abc_Order_Date__c, TotalAmount, Account.Name
    FROM Order
    WHERE Status = 'Delivered' AND abc_Order_Date__c < :cutoff
    ORDER BY abc_Order_Date__c ASC
];

System.debug(LoggingLevel.ERROR, '=== ABC order archival ===');
System.debug(LoggingLevel.ERROR, 'Cutoff: order date before ' + cutoff.format());
System.debug(LoggingLevel.ERROR, 'Orders that qualify: ' + candidates.size());
for (Order o : candidates) {
    System.debug(
        LoggingLevel.ERROR,
        '  ' + o.OrderNumber + ' | ' + o.Status + ' | ordered ' + o.abc_Order_Date__c +
            ' | ' + o.Account.Name + ' | ' + o.TotalAmount
    );
}

if (candidates.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'Nothing to archive. Seed an order with abc_Order_Date__c older than a year first.');
} else {
    Id jobId = Database.executeBatch(new abc_OrderArchiveBatch(), abc_OrderArchiveBatch.SCOPE_SIZE);
    System.debug(LoggingLevel.ERROR, 'Batch submitted. AsyncApexJob id: ' + jobId);
    System.debug(
        LoggingLevel.ERROR,
        'Check progress with: sf data query -o abcDev -q "SELECT Status, JobItemsProcessed, ' +
            'TotalJobItems, NumberOfErrors FROM AsyncApexJob WHERE Id = \'' + jobId + '\'"'
    );
}
