/**
 * Shared test data builder for the ABC pharmacy solution.
 *
 * Every test in this project builds its fixtures here so that the awkward parts
 * of the standard order model are handled in exactly one place:
 *
 *  - an Order must be inserted with a Draft-coded Status and a Pricebook2Id
 *    before any OrderItem can be attached;
 *  - "In delivery" and "Delivered" are Activated-coded, so an order only reaches
 *    them by a later update, never on insert;
 *  - an OrderItem needs PricebookEntryId, Quantity and UnitPrice together;
 *  - CreatedDate can only be moved with Test.setCreatedDate, which is how the
 *    Visualforce icon rules get an order that was "created in the past".
 */
@IsTest
public class abc_TestDataFactory {
    public static final String CATEGORY_MEDICINE = 'Medicine';
    public static final String CATEGORY_SUPPLEMENT = 'Supplement';
    public static final String CATEGORY_PERSONAL_CARE = 'Personal Care';
    public static final String CATEGORY_MEDICAL_DEVICE = 'Medical Device';

    public static final String STATUS_DRAFT = 'Draft';
    public static final String STATUS_ACTIVATED = 'Activated';
    public static final String STATUS_IN_DELIVERY = 'In delivery';
    public static final String STATUS_DELIVERED = 'Delivered';

    public static final String CHANNEL_MANUAL = 'Manual';
    public static final String CHANNEL_IONIC = 'Ionic App';

    /** The org's standard price book. In a test context this is the only one that works. */
    public static Id standardPricebookId() {
        return Test.getStandardPricebookId();
    }

    // ---------------------------------------------------------------- products

    public static Product2 buildProduct(String name, String code, String category, Decimal stock, Boolean rx) {
        return new Product2(
            Name = name,
            ProductCode = code,
            Description = name + ' - test fixture',
            IsActive = true,
            abc_Category__c = category,
            abc_Stock_Quantity__c = stock,
            abc_Requires_Prescription__c = rx
        );
    }

    /**
     * Inserts count products with an active standard price book entry each.
     * Unit price is 10, 20, 30 ... so assertions on totals stay readable.
     */
    public static List<Product2> createProducts(Integer count) {
        List<Product2> products = new List<Product2>();
        for (Integer i = 1; i <= count; i++) {
            products.add(buildProduct('ABC Test Product ' + i, 'ABC-T-' + i, CATEGORY_MEDICINE, 100, false));
        }
        insert products;
        createPricebookEntries(products);
        return products;
    }

    /** One active standard price book entry per product, priced at 10 x its position. */
    public static List<PricebookEntry> createPricebookEntries(List<Product2> products) {
        Id pricebookId = standardPricebookId();
        List<PricebookEntry> entries = new List<PricebookEntry>();
        Integer i = 1;
        for (Product2 p : products) {
            entries.add(
                new PricebookEntry(
                    Pricebook2Id = pricebookId,
                    Product2Id = p.Id,
                    UnitPrice = 10 * i,
                    IsActive = true,
                    UseStandardPrice = false
                )
            );
            i++;
        }
        insert entries;
        return entries;
    }

    public static PricebookEntry createPricebookEntry(Product2 product, Decimal unitPrice) {
        PricebookEntry entry = new PricebookEntry(
            Pricebook2Id = standardPricebookId(),
            Product2Id = product.Id,
            UnitPrice = unitPrice,
            IsActive = true,
            UseStandardPrice = false
        );
        insert entry;
        return entry;
    }

    public static List<PricebookEntry> queryPricebookEntries(List<Product2> products) {
        Set<Id> productIds = new Map<Id, Product2>(products).keySet();
        return [
            SELECT Id, Product2Id, UnitPrice, Product2.Name, Product2.abc_Stock_Quantity__c
            FROM PricebookEntry
            WHERE Product2Id IN :productIds AND Pricebook2Id = :standardPricebookId()
            ORDER BY UnitPrice ASC
        ];
    }

    // --------------------------------------------------------------- customers

    /** A customer is an Account plus the Contact the Ionic app identifies by email. */
    public static Account createCustomer(String firstName, String lastName, String email) {
        Account account = new Account(Name = firstName + ' ' + lastName);
        insert account;
        insert new Contact(AccountId = account.Id, FirstName = firstName, LastName = lastName, Email = email);
        return account;
    }

    public static Contact contactFor(Id accountId) {
        return [SELECT Id, AccountId, Email, Name FROM Contact WHERE AccountId = :accountId LIMIT 1];
    }

    // ------------------------------------------------------------------ orders

    /** A cart: a Draft order wired to the standard price book so items can be added. */
    public static Order createDraftOrder(Id accountId, Id contactId) {
        return createDraftOrder(accountId, contactId, Date.today(), CHANNEL_MANUAL);
    }

    public static Order createDraftOrder(Id accountId, Id contactId, Date orderDate, String channel) {
        Order order = new Order(
            AccountId = accountId,
            BillToContactId = contactId,
            Status = STATUS_DRAFT,
            EffectiveDate = orderDate,
            abc_Order_Date__c = orderDate,
            abc_Channel__c = channel,
            Pricebook2Id = standardPricebookId()
        );
        insert order;
        return order;
    }

    public static OrderItem addItem(Id orderId, PricebookEntry entry, Integer quantity) {
        OrderItem item = new OrderItem(
            OrderId = orderId,
            PricebookEntryId = entry.Id,
            Quantity = quantity,
            UnitPrice = entry.UnitPrice
        );
        insert item;
        return item;
    }

    public static List<OrderItem> addItems(Id orderId, List<PricebookEntry> entries, List<Integer> quantities) {
        List<OrderItem> items = new List<OrderItem>();
        for (Integer i = 0; i < entries.size(); i++) {
            items.add(
                new OrderItem(
                    OrderId = orderId,
                    PricebookEntryId = entries[i].Id,
                    Quantity = quantities[i],
                    UnitPrice = entries[i].UnitPrice
                )
            );
        }
        insert items;
        return items;
    }

    /**
     * Builds a complete order in the only sequence the platform allows:
     * insert as Draft with the price book, attach the items, then move the
     * status on. Returns the requeried order.
     */
    public static Order createOrderWithItems(
        Id accountId,
        Id contactId,
        List<PricebookEntry> entries,
        List<Integer> quantities,
        String finalStatus,
        Date orderDate
    ) {
        Order order = createDraftOrder(accountId, contactId, orderDate, CHANNEL_MANUAL);
        addItems(order.Id, entries, quantities);

        if (finalStatus != null && finalStatus != STATUS_DRAFT) {
            order.Status = finalStatus;
            if (finalStatus == STATUS_DELIVERED) {
                order.abc_Delivered_Date__c = orderDate.addDays(2) > Date.today()
                    ? Date.today()
                    : orderDate.addDays(2);
            }
            update order;
        }
        return [
            SELECT Id, OrderNumber, Status, StatusCode, EffectiveDate, TotalAmount, CreatedDate, AccountId,
                abc_Order_Date__c, abc_Delivered_Date__c, abc_Channel__c
            FROM Order
            WHERE Id = :order.Id
        ];
    }

    /**
     * Moves a record's CreatedDate into the past. Only possible inside a test,
     * which is precisely why the Visualforce icon tests live there.
     */
    public static void backdateCreation(Id recordId, Integer daysAgo) {
        Test.setCreatedDate(recordId, System.now().addDays(-daysAgo));
    }

    // ------------------------------------------------------------------- users

    /**
     * A Standard User holding nothing but the named permission set, used with
     * System.runAs to prove least-privilege access. Test users do not consume a
     * license, so this works even though a Developer Edition org has very few.
     */
    public static User createUserWithPermissionSet(String alias, String permissionSetName) {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(Datetime.now().getTime()) + String.valueOf(Math.abs(Crypto.getRandomInteger()));

        User user = new User(
            Alias = alias,
            Email = alias + '@abc-pharmacy-test.example.com',
            EmailEncodingKey = 'UTF-8',
            FirstName = 'ABC',
            LastName = 'Tester ' + alias,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Africa/Cairo',
            Username = 'abc.' + alias + '.' + unique + '@abc-pharmacy-test.example.com'
        );
        insert user;

        if (String.isNotBlank(permissionSetName)) {
            PermissionSet permissionSet = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = permissionSet.Id);
        }
        return user;
    }
}
