/**
 * Seeds the ABC pharmacy demo data set.
 *
 *   sf apex run --file scripts/apex/abc_seed_data.apex --target-org abcDev
 *
 * Creates a catalogue, three customers and five orders chosen so that every
 * behaviour in the solution can be seen without creating anything by hand:
 *
 *   A  Draft, created today        -> the cart state, and the hourglass-start icon
 *   B  Activated, created 45 days ago -> the hourglass-done icon
 *   C  In delivery                 -> the truck icon
 *   D  Delivered, ordered 30 days ago -> the tick icon, too recent to archive
 *   E  Delivered, ordered 400 days ago -> the tick icon, and the batch's target
 *
 * Orders B, D and E need a CreatedDate in the past. That is only possible when
 * Setup > User Interface > "Set Audit Fields upon Record Creation" is enabled
 * and the running user holds the resulting permission; the script detects this
 * and carries on without backdating if it is off, telling you what it skipped.
 *
 * Safe to re-run: it stops if the catalogue is already present.
 */
final String PRODUCT_PREFIX = 'ABC-';

// ---------------------------------------------------------------- guard rails

List<Product2> existing = [SELECT Id FROM Product2 WHERE ProductCode LIKE :(PRODUCT_PREFIX + '%') LIMIT 1];
if (!existing.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'ABC seed data already present - nothing to do. Delete it first to re-seed.');
    return;
}

Boolean canBackdate = Schema.SObjectType.Order.fields.CreatedDate.isCreateable();
System.debug(LoggingLevel.INFO, 'Backdating of CreatedDate is ' + (canBackdate ? 'AVAILABLE' : 'NOT AVAILABLE'));

// ------------------------------------------------------------- price book

Pricebook2 standardPricebook = [SELECT Id, IsActive FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
if (!standardPricebook.IsActive) {
    standardPricebook.IsActive = true;
    update standardPricebook;
    System.debug(LoggingLevel.INFO, 'Activated the standard price book.');
}

// -------------------------------------------------------------- catalogue

List<Product2> products = new List<Product2>{
    new Product2(Name = 'Paracetamol 500mg Tablets (20)', ProductCode = 'ABC-MED-001', Family = 'Medicine',
        Description = 'Analgesic and antipyretic tablets, blister pack of 20.',
        IsActive = true, abc_Category__c = 'Medicine', abc_Stock_Quantity__c = 500, abc_Requires_Prescription__c = false),
    new Product2(Name = 'Amoxicillin 250mg Capsules (21)', ProductCode = 'ABC-MED-002', Family = 'Medicine',
        Description = 'Broad spectrum antibiotic capsules. Prescription only.',
        IsActive = true, abc_Category__c = 'Medicine', abc_Stock_Quantity__c = 220, abc_Requires_Prescription__c = true),
    new Product2(Name = 'Ibuprofen 400mg Tablets (24)', ProductCode = 'ABC-MED-003', Family = 'Medicine',
        Description = 'Non-steroidal anti-inflammatory tablets.',
        IsActive = true, abc_Category__c = 'Medicine', abc_Stock_Quantity__c = 380, abc_Requires_Prescription__c = false),
    new Product2(Name = 'Insulin Glargine 100IU/ml Pen', ProductCode = 'ABC-MED-004', Family = 'Medicine',
        Description = 'Long acting insulin pen, cold chain. Prescription only.',
        IsActive = true, abc_Category__c = 'Medicine', abc_Stock_Quantity__c = 60, abc_Requires_Prescription__c = true),
    new Product2(Name = 'Vitamin D3 1000IU Softgels (60)', ProductCode = 'ABC-SUP-001', Family = 'Supplement',
        Description = 'Daily vitamin D supplement.',
        IsActive = true, abc_Category__c = 'Supplement', abc_Stock_Quantity__c = 150, abc_Requires_Prescription__c = false),
    new Product2(Name = 'Omega-3 Fish Oil 1000mg (90)', ProductCode = 'ABC-SUP-002', Family = 'Supplement',
        Description = 'High strength omega-3 softgels.',
        IsActive = true, abc_Category__c = 'Supplement', abc_Stock_Quantity__c = 95, abc_Requires_Prescription__c = false),
    new Product2(Name = 'Hand Sanitiser Gel 500ml', ProductCode = 'ABC-PC-001', Family = 'Personal Care',
        Description = 'Alcohol based hand sanitiser with pump dispenser.',
        IsActive = true, abc_Category__c = 'Personal Care', abc_Stock_Quantity__c = 400, abc_Requires_Prescription__c = false),
    new Product2(Name = 'Sunscreen SPF 50+ 100ml', ProductCode = 'ABC-PC-002', Family = 'Personal Care',
        Description = 'Broad spectrum sunscreen lotion.',
        IsActive = true, abc_Category__c = 'Personal Care', abc_Stock_Quantity__c = 75, abc_Requires_Prescription__c = false),
    new Product2(Name = 'Digital Blood Pressure Monitor', ProductCode = 'ABC-DEV-001', Family = 'Medical Device',
        Description = 'Upper arm automatic blood pressure monitor.',
        IsActive = true, abc_Category__c = 'Medical Device', abc_Stock_Quantity__c = 25, abc_Requires_Prescription__c = false),
    new Product2(Name = 'Fingertip Pulse Oximeter', ProductCode = 'ABC-DEV-002', Family = 'Medical Device',
        Description = 'Fingertip SpO2 and pulse rate monitor. Currently out of stock.',
        IsActive = true, abc_Category__c = 'Medical Device', abc_Stock_Quantity__c = 0, abc_Requires_Prescription__c = false)
};
insert products;

Map<String, Decimal> priceByCode = new Map<String, Decimal>{
    'ABC-MED-001' => 12.50,
    'ABC-MED-002' => 45.00,
    'ABC-MED-003' => 18.75,
    'ABC-MED-004' => 310.00,
    'ABC-SUP-001' => 89.00,
    'ABC-SUP-002' => 120.00,
    'ABC-PC-001' => 35.00,
    'ABC-PC-002' => 145.00,
    'ABC-DEV-001' => 850.00,
    'ABC-DEV-002' => 275.00
};

List<PricebookEntry> entries = new List<PricebookEntry>();
for (Product2 p : products) {
    entries.add(new PricebookEntry(
        Pricebook2Id = standardPricebook.Id,
        Product2Id = p.Id,
        UnitPrice = priceByCode.get(p.ProductCode),
        IsActive = true,
        UseStandardPrice = false
    ));
}
insert entries;

Map<String, PricebookEntry> entryByCode = new Map<String, PricebookEntry>();
for (PricebookEntry e : [SELECT Id, UnitPrice, Product2.ProductCode FROM PricebookEntry WHERE Id IN :entries]) {
    entryByCode.put(e.Product2.ProductCode, e);
}

// -------------------------------------------------------------- customers

List<Account> accounts = new List<Account>{
    new Account(Name = 'Mona Hassan', Description = 'ABC pharmacy retail customer.'),
    new Account(Name = 'Karim Adel', Description = 'ABC pharmacy retail customer.'),
    new Account(Name = 'Salma Ibrahim', Description = 'ABC pharmacy retail customer.')
};
insert accounts;

List<Contact> contacts = new List<Contact>{
    new Contact(AccountId = accounts[0].Id, FirstName = 'Mona', LastName = 'Hassan',
        Email = 'mona.hassan@example.com', Phone = '+20 100 111 2222'),
    new Contact(AccountId = accounts[1].Id, FirstName = 'Karim', LastName = 'Adel',
        Email = 'karim.adel@example.com', Phone = '+20 100 333 4444'),
    new Contact(AccountId = accounts[2].Id, FirstName = 'Salma', LastName = 'Ibrahim',
        Email = 'salma.ibrahim@example.com', Phone = '+20 100 555 6666')
};
insert contacts;

// ----------------------------------------------------------------- orders
//
// Every order is inserted as Draft with the standard price book, because that
// is the only state in which OrderItems can be attached. The fulfilment states
// are applied afterwards by update.

Date today = Date.today();

List<Order> orders = new List<Order>{
    new Order(AccountId = accounts[0].Id, BillToContactId = contacts[0].Id, Status = 'Draft',
        EffectiveDate = today, abc_Order_Date__c = today, abc_Channel__c = 'Ionic App',
        Pricebook2Id = standardPricebook.Id, Description = 'A - open cart created today'),
    new Order(AccountId = accounts[1].Id, BillToContactId = contacts[1].Id, Status = 'Draft',
        EffectiveDate = today.addDays(-45), abc_Order_Date__c = today.addDays(-45), abc_Channel__c = 'Manual',
        Pricebook2Id = standardPricebook.Id, Description = 'B - activated, placed 45 days ago'),
    new Order(AccountId = accounts[2].Id, BillToContactId = contacts[2].Id, Status = 'Draft',
        EffectiveDate = today.addDays(-3), abc_Order_Date__c = today.addDays(-3), abc_Channel__c = 'Ionic App',
        Pricebook2Id = standardPricebook.Id, Description = 'C - out with the driver'),
    new Order(AccountId = accounts[0].Id, BillToContactId = contacts[0].Id, Status = 'Draft',
        EffectiveDate = today.addDays(-30), abc_Order_Date__c = today.addDays(-30), abc_Channel__c = 'Manual',
        Pricebook2Id = standardPricebook.Id, Description = 'D - delivered recently, too new to archive'),
    new Order(AccountId = accounts[1].Id, BillToContactId = contacts[1].Id, Status = 'Draft',
        EffectiveDate = today.addDays(-400), abc_Order_Date__c = today.addDays(-400), abc_Channel__c = 'Ionic App',
        Pricebook2Id = standardPricebook.Id, Description = 'E - delivered over a year ago, the batch archives this one')
};

// Written through put() rather than as orders[1].CreatedDate = ... on purpose.
// While "Set Audit Fields upon Record Creation" is switched off, CreatedDate is
// not writeable and the static form does not even compile, so the script would
// be unusable in exactly the org state it is meant to detect. Dynamic field
// access compiles either way and the guard above decides at run time.
if (canBackdate) {
    orders[1].put('CreatedDate', System.now().addDays(-45));
    orders[2].put('CreatedDate', System.now().addDays(-3));
    orders[3].put('CreatedDate', System.now().addDays(-30));
    orders[4].put('CreatedDate', System.now().addDays(-400));
}
insert orders;

List<OrderItem> items = new List<OrderItem>{
    // A - open cart
    new OrderItem(OrderId = orders[0].Id, PricebookEntryId = entryByCode.get('ABC-MED-001').Id,
        Quantity = 2, UnitPrice = entryByCode.get('ABC-MED-001').UnitPrice),
    new OrderItem(OrderId = orders[0].Id, PricebookEntryId = entryByCode.get('ABC-SUP-001').Id,
        Quantity = 1, UnitPrice = entryByCode.get('ABC-SUP-001').UnitPrice),
    // B - activated
    new OrderItem(OrderId = orders[1].Id, PricebookEntryId = entryByCode.get('ABC-MED-003').Id,
        Quantity = 3, UnitPrice = entryByCode.get('ABC-MED-003').UnitPrice),
    new OrderItem(OrderId = orders[1].Id, PricebookEntryId = entryByCode.get('ABC-PC-001').Id,
        Quantity = 2, UnitPrice = entryByCode.get('ABC-PC-001').UnitPrice),
    // C - in delivery
    new OrderItem(OrderId = orders[2].Id, PricebookEntryId = entryByCode.get('ABC-DEV-001').Id,
        Quantity = 1, UnitPrice = entryByCode.get('ABC-DEV-001').UnitPrice),
    new OrderItem(OrderId = orders[2].Id, PricebookEntryId = entryByCode.get('ABC-MED-002').Id,
        Quantity = 1, UnitPrice = entryByCode.get('ABC-MED-002').UnitPrice),
    new OrderItem(OrderId = orders[2].Id, PricebookEntryId = entryByCode.get('ABC-SUP-002').Id,
        Quantity = 2, UnitPrice = entryByCode.get('ABC-SUP-002').UnitPrice),
    // D - delivered recently
    new OrderItem(OrderId = orders[3].Id, PricebookEntryId = entryByCode.get('ABC-PC-002').Id,
        Quantity = 1, UnitPrice = entryByCode.get('ABC-PC-002').UnitPrice),
    new OrderItem(OrderId = orders[3].Id, PricebookEntryId = entryByCode.get('ABC-MED-001').Id,
        Quantity = 4, UnitPrice = entryByCode.get('ABC-MED-001').UnitPrice),
    // E - delivered over a year ago
    new OrderItem(OrderId = orders[4].Id, PricebookEntryId = entryByCode.get('ABC-MED-004').Id,
        Quantity = 1, UnitPrice = entryByCode.get('ABC-MED-004').UnitPrice),
    new OrderItem(OrderId = orders[4].Id, PricebookEntryId = entryByCode.get('ABC-SUP-001').Id,
        Quantity = 2, UnitPrice = entryByCode.get('ABC-SUP-001').UnitPrice),
    new OrderItem(OrderId = orders[4].Id, PricebookEntryId = entryByCode.get('ABC-PC-001').Id,
        Quantity = 1, UnitPrice = entryByCode.get('ABC-PC-001').UnitPrice)
};
insert items;

// Now move each order to its final state. Order A stays a Draft cart.
orders[1].Status = 'Activated';
orders[2].Status = 'In delivery';
orders[3].Status = 'Delivered';
orders[3].abc_Delivered_Date__c = today.addDays(-27);
orders[4].Status = 'Delivered';
orders[4].abc_Delivered_Date__c = today.addDays(-396);
update new List<Order>{ orders[1], orders[2], orders[3], orders[4] };

// ----------------------------------------------------------------- report

for (Order o : [
    SELECT OrderNumber, Status, StatusCode, EffectiveDate, CreatedDate, TotalAmount, Account.Name,
        abc_Order_Date__c, abc_Channel__c, Description
    FROM Order
    ORDER BY abc_Order_Date__c DESC
]) {
    System.debug(LoggingLevel.INFO, String.format(
        '{0} | {1} ({2}) | ordered {3} | created {4} | {5} | {6} | {7}',
        new List<String>{
            o.OrderNumber, o.Status, o.StatusCode, String.valueOf(o.abc_Order_Date__c),
            o.CreatedDate.format('yyyy-MM-dd'), String.valueOf(o.TotalAmount), o.Account.Name, o.Description
        }
    ));
}
System.debug(LoggingLevel.INFO, 'Seeded ' + products.size() + ' products, ' + accounts.size() +
    ' customers and ' + orders.size() + ' orders. Backdated CreatedDate: ' + canBackdate);
