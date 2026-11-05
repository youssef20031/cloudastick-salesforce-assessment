// Removes everything the demo created in abcDev: its orders, customer, product and ticket Cases.
// Nothing else is touched. Each record is found by the demo's own product code, email or subject.
final String PRODUCT_CODE = 'ABC-DEMO-SALB';
final String CUSTOMER_EMAIL = 'nadia.farouk.demo@example.com';

List<Order> orders = [
    SELECT Id, Status
    FROM Order
    WHERE BillToContact.Email = :CUSTOMER_EMAIL
];
List<Order> toDraft = new List<Order>();
for (Order existing : orders) {
    if (existing.Status != 'Draft') {
        toDraft.add(new Order(Id = existing.Id, Status = 'Draft'));
    }
}
update toDraft;
delete orders;

delete [SELECT Id FROM Case WHERE Subject LIKE '%Salbutamol%'];
delete [SELECT Id FROM Product2 WHERE ProductCode = :PRODUCT_CODE];

List<Contact> contacts = [SELECT Id, AccountId FROM Contact WHERE Email = :CUSTOMER_EMAIL];
Set<Id> accountIds = new Set<Id>();
for (Contact existing : contacts) {
    accountIds.add(existing.AccountId);
}
delete contacts;
delete [SELECT Id FROM Account WHERE Id IN :accountIds];

System.debug('DEMO teardown finished: ' + orders.size() + ' orders removed.');
