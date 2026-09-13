/**
 * Creates one more Delivered order dated 400 days ago, so the archival batch
 * has something to pick up.
 *
 *   sf apex run --file scripts/apex/abc_seed_archivable_order.apex --target-org abcDev
 *
 * Use this to re-arm the demo after running abc_run_archive_now.apex, which
 * deletes the orders it archives. Requires the catalogue from
 * abc_seed_data.apex to exist.
 *
 * The order is built in the only sequence the platform allows: insert as Draft
 * with the standard price book, attach the line items, then move the status to
 * Delivered.
 */
Pricebook2 standardPricebook = [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1];

// Prefer a customer seeded by abc_seed_data.apex over the sample data a
// Developer Edition org ships with, so the demo order hangs off an ABC customer.
List<Contact> customers = [
    SELECT Id, AccountId, Name
    FROM Contact
    WHERE Email LIKE '%@example.com' AND AccountId != NULL
    ORDER BY CreatedDate ASC
    LIMIT 1
];
if (customers.isEmpty()) {
    customers = [SELECT Id, AccountId, Name FROM Contact WHERE Email != NULL AND AccountId != NULL LIMIT 1];
}
if (customers.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'No customers found. Run scripts/apex/abc_seed_data.apex first.');
    return;
}
Contact buyer = customers[0];

Map<String, PricebookEntry> entryByCode = new Map<String, PricebookEntry>();
for (PricebookEntry e : [
    SELECT Id, UnitPrice, Product2.ProductCode
    FROM PricebookEntry
    WHERE Pricebook2Id = :standardPricebook.Id AND IsActive = TRUE AND Product2.ProductCode LIKE 'ABC-%'
]) {
    entryByCode.put(e.Product2.ProductCode, e);
}
if (entryByCode.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'No ABC catalogue found. Run scripts/apex/abc_seed_data.apex first.');
    return;
}

Date placed = Date.today().addDays(-400);

Order order = new Order(
    AccountId = buyer.AccountId,
    BillToContactId = buyer.Id,
    Status = 'Draft',
    EffectiveDate = placed,
    abc_Order_Date__c = placed,
    abc_Channel__c = 'Manual',
    Pricebook2Id = standardPricebook.Id,
    Description = 'Archival demo - delivered over a year ago'
);
insert order;

List<OrderItem> items = new List<OrderItem>();
for (String code : new List<String>{ 'ABC-MED-001', 'ABC-SUP-002' }) {
    PricebookEntry entry = entryByCode.get(code);
    if (entry != null) {
        items.add(
            new OrderItem(OrderId = order.Id, PricebookEntryId = entry.Id, Quantity = 2, UnitPrice = entry.UnitPrice)
        );
    }
}
insert items;

order.Status = 'Delivered';
order.abc_Delivered_Date__c = placed.addDays(4);
update order;

Order created = [
    SELECT OrderNumber, Status, StatusCode, abc_Order_Date__c, TotalAmount, Account.Name
    FROM Order
    WHERE Id = :order.Id
];
System.debug(
    LoggingLevel.ERROR,
    'Created ' + created.OrderNumber + ' | ' + created.Status + ' (' + created.StatusCode + ')' +
        ' | ordered ' + created.abc_Order_Date__c + ' | ' + created.Account.Name + ' | ' + created.TotalAmount
);
System.debug(LoggingLevel.ERROR, 'Now run scripts/apex/abc_run_archive_now.apex to archive it.');
