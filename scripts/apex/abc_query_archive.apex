/**
 * Reads the abc_Order_Archive__b big object back and prints each archived
 * order with its line items.
 *
 *   sf apex run --file scripts/apex/abc_query_archive.apex --target-org abcDev
 *
 * Big object SOQL is not ordinary SOQL. Three rules shape the query below:
 *
 *  1. You may only filter on the index fields, in index order. The index here
 *     is [abc_Order_Date__c DESC, abc_Order_Number__c ASC], so the first filter
 *     must be on abc_Order_Date__c. A wide range filter is the idiom for
 *     "everything".
 *  2. Aggregate functions are unsupported - SELECT COUNT() fails outright, so
 *     the row count is taken from the returned list.
 *  3. "!=" and LIKE are unsupported in the filter.
 */
Datetime windowStart = Datetime.newInstance(1990, 1, 1, 0, 0, 0);

List<abc_Order_Archive__b> archived = [
    SELECT
        abc_Order_Date__c,
        abc_Order_Number__c,
        abc_Order_Id__c,
        abc_Account_Id__c,
        abc_Account_Name__c,
        abc_Status__c,
        abc_Channel__c,
        abc_Effective_Date__c,
        abc_Delivered_Date__c,
        abc_Total_Amount__c,
        abc_Archived_On__c,
        abc_Line_Items_JSON__c
    FROM abc_Order_Archive__b
    WHERE abc_Order_Date__c >= :windowStart
    LIMIT 200
];

System.debug(LoggingLevel.ERROR, '=== abc_Order_Archive__b ===');
System.debug(LoggingLevel.ERROR, 'Archived orders found: ' + archived.size());

for (abc_Order_Archive__b row : archived) {
    System.debug(
        LoggingLevel.ERROR,
        '--- ' + row.abc_Order_Number__c +
            ' | ordered ' + row.abc_Order_Date__c.format('yyyy-MM-dd') +
            ' | ' + row.abc_Status__c +
            ' | ' + row.abc_Account_Name__c +
            ' | total ' + row.abc_Total_Amount__c +
            ' | channel ' + row.abc_Channel__c +
            ' | archived ' + row.abc_Archived_On__c.format('yyyy-MM-dd HH:mm')
    );

    if (String.isBlank(row.abc_Line_Items_JSON__c)) {
        System.debug(LoggingLevel.ERROR, '      (no line items recorded)');
        continue;
    }
    List<abc_OrderArchiveBatch.LineItem> items = (List<abc_OrderArchiveBatch.LineItem>) JSON.deserialize(
        row.abc_Line_Items_JSON__c,
        List<abc_OrderArchiveBatch.LineItem>.class
    );
    for (abc_OrderArchiveBatch.LineItem item : items) {
        System.debug(
            LoggingLevel.ERROR,
            '      ' + item.productName + ' (' + item.productCode + ') x' + item.quantity +
                ' @ ' + item.unitPrice + ' = ' + item.totalPrice
        );
    }
}

// Proof the orders really left the Order object.
System.debug(LoggingLevel.ERROR, '=== Orders still in Salesforce ===');
for (Order o : [
    SELECT OrderNumber, Status, abc_Order_Date__c
    FROM Order
    ORDER BY abc_Order_Date__c DESC
]) {
    System.debug(
        LoggingLevel.ERROR,
        '  ' + o.OrderNumber + ' | ' + o.Status + ' | ordered ' + o.abc_Order_Date__c
    );
}
