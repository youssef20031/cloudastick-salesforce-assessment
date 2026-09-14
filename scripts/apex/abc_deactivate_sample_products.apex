/**
 * Deactivates the sample products a Developer Edition org ships with.
 *
 *   sf apex run --file scripts/apex/abc_deactivate_sample_products.apex --target-org abcDev
 *
 * Why this is needed
 * ------------------
 * A fresh Developer Edition org arrives with a demo catalogue - GenWatt
 * generators, "SLA: Gold", "Installation: Portable" and so on. Those products
 * are active and they carry active standard price book entries, which is
 * exactly what abc_ProductService defines a sellable product to be, so they
 * are returned by GET /abc/v1/products alongside the pharmacy catalogue.
 *
 * They do not show up in the default listing, but only by accident: their
 * abc_Stock_Quantity__c is null, and `null > 0` is false in SOQL, so the
 * in-stock clause filters them out. Call the endpoint with
 * includeOutOfStock=true - as the Postman collection does - and a pharmacy
 * catalogue starts listing diesel generators.
 *
 * Deactivating them is the honest fix for the data: a pharmacy org has no
 * business holding generator sample records. The service keeps its definition
 * of a sellable product (active, and in the standard price book), which is the
 * correct definition for a real org.
 *
 * Safe to run more than once, and safe to run in a fresh org: it only touches
 * products outside the ABC- catalogue, and it refuses to touch any product
 * that an order already references.
 */
Set<Id> productsOnOrders = new Set<Id>();
for (OrderItem line : [SELECT Product2Id FROM OrderItem WHERE Product2Id != NULL]) {
    productsOnOrders.add(line.Product2Id);
}

List<Product2> toDeactivate = new List<Product2>();
List<String> skipped = new List<String>();

for (Product2 p : [
    SELECT Id, Name, ProductCode
    FROM Product2
    WHERE IsActive = TRUE AND (NOT ProductCode LIKE 'ABC-%')
]) {
    if (productsOnOrders.contains(p.Id)) {
        // An order depends on it, so leave it alone and say so.
        skipped.add(p.ProductCode + ' ' + p.Name);
        continue;
    }
    toDeactivate.add(new Product2(Id = p.Id, IsActive = false));
}

if (toDeactivate.isEmpty()) {
    System.debug(LoggingLevel.ERROR, 'Nothing to do - no active non-ABC products found.');
} else {
    update toDeactivate;
    System.debug(LoggingLevel.ERROR, 'Deactivated ' + toDeactivate.size() + ' sample product(s).');
}

for (String s : skipped) {
    System.debug(LoggingLevel.ERROR, 'SKIPPED (referenced by an order): ' + s);
}

Integer remaining = [
    SELECT COUNT()
    FROM Product2
    WHERE IsActive = TRUE AND (NOT ProductCode LIKE 'ABC-%')
];
Integer catalogue = [SELECT COUNT() FROM Product2 WHERE IsActive = TRUE AND ProductCode LIKE 'ABC-%'];
System.debug(LoggingLevel.ERROR, 'Active ABC products: ' + catalogue + ' | active non-ABC products: ' + remaining);
