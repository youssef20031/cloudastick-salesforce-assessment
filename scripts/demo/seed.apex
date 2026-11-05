// Sets up the bug the ticket reports, using the real cart service so that the data is honest.
//  1. Two carts each hold 2 Salbutamol inhalers while 4 are in stock.
//  2. The stock sells out elsewhere.
//  3. The first cart checks out anyway. This is the order in the ticket.
//  4. The second stays Draft: after the fix, its checkout must be refused.
// Needs the unfixed abc_CartService, which is why reset.sh restores the class first.
final String PRODUCT_CODE = 'ABC-DEMO-SALB';
final String CUSTOMER_EMAIL = 'nadia.farouk.demo@example.com';

Product2 product = new Product2(
    Name = 'Salbutamol Inhaler 100mcg',
    ProductCode = PRODUCT_CODE,
    abc_Category__c = [SELECT abc_Category__c FROM Product2 WHERE abc_Category__c != NULL LIMIT 1].abc_Category__c,
    abc_Stock_Quantity__c = 4,
    IsActive = true
);
insert product;
insert new PricebookEntry(
    Pricebook2Id = abc_ProductService.standardPricebookId(),
    Product2Id = product.Id,
    UnitPrice = 12.50,
    IsActive = true
);

String body = JSON.serialize(new Map<String, Object>{
    'customer' => new Map<String, Object>{
        'firstName' => 'Nadia',
        'lastName' => 'Farouk',
        'email' => CUSTOMER_EMAIL
    },
    'items' => new List<Object>{
        new Map<String, Object>{ 'productId' => product.Id, 'quantity' => 2 }
    }
});
abc_ApiModels.CartDto ordered = abc_CartService.createCart(
    (abc_ApiModels.CreateCartRequest) JSON.deserialize(body, abc_ApiModels.CreateCartRequest.class)
);
abc_ApiModels.CartDto waiting = abc_CartService.createCart(
    (abc_ApiModels.CreateCartRequest) JSON.deserialize(body, abc_ApiModels.CreateCartRequest.class)
);

update new Product2(Id = product.Id, abc_Stock_Quantity__c = 0);

abc_ApiModels.CartDto placed = abc_CartService.checkout(ordered.cartId);
System.debug('DEMO placed order ' + placed.orderNumber + ' (' + placed.status + ') with stock at zero.');
System.debug('DEMO waiting cart ' + waiting.cartId + ' (' + waiting.orderNumber + ').');
