/**
 * Removes everything abc_seed_data.apex created, so it can be run again.
 *
 *   sf apex run --file scripts/apex/abc_delete_seed_data.apex --target-org abcDev
 *
 * Deletes, in dependency order: orders (line items go with them), the ABC
 * customers, and the ABC catalogue with its price book entries.
 *
 * Two things it deliberately does NOT touch:
 *   - rows already written to abc_Order_Archive__b. Those are the archive; the
 *     point of an archive is that it outlives the record. Remove them by hand
 *     with Database.deleteImmediate if you really need a clean slate.
 *   - anything outside the ABC data set - products are matched on the ABC-
 *     product code prefix and customers on their @example.com addresses.
 *
 * An order whose status is Activated-coded ("Activated", "In delivery",
 * "Delivered") cannot be deleted, so every order is set back to Draft first.
 */
List<Order> orders = [SELECT Id, OrderNumber, Status FROM Order];
if (!orders.isEmpty()) {
    List<Order> toDraft = new List<Order>();
    for (Order o : orders) {
        if (o.Status != 'Draft') {
            toDraft.add(new Order(Id = o.Id, Status = 'Draft'));
        }
    }
    if (!toDraft.isEmpty()) {
        update toDraft;
        System.debug(LoggingLevel.ERROR, 'Set ' + toDraft.size() + ' order(s) back to Draft so they can be deleted.');
    }
    delete orders;
    System.debug(LoggingLevel.ERROR, 'Deleted ' + orders.size() + ' order(s) and their line items.');
}

List<Account> customers = [SELECT Id FROM Account WHERE Id IN (SELECT AccountId FROM Contact WHERE Email LIKE '%@example.com')];
if (!customers.isEmpty()) {
    delete customers;
    System.debug(LoggingLevel.ERROR, 'Deleted ' + customers.size() + ' ABC customer account(s) and their contacts.');
}

List<PricebookEntry> entries = [SELECT Id FROM PricebookEntry WHERE Product2.ProductCode LIKE 'ABC-%'];
if (!entries.isEmpty()) {
    delete entries;
    System.debug(LoggingLevel.ERROR, 'Deleted ' + entries.size() + ' price book entry/entries.');
}

List<Product2> products = [SELECT Id FROM Product2 WHERE ProductCode LIKE 'ABC-%'];
if (!products.isEmpty()) {
    delete products;
    System.debug(LoggingLevel.ERROR, 'Deleted ' + products.size() + ' ABC product(s).');
}

System.debug(LoggingLevel.ERROR, 'Done. Run scripts/apex/abc_seed_data.apex to rebuild the demo data.');
