/**
 * The shopping cart, expressed in the standard order model.
 *
 * A cart *is* an Order in Draft status: no separate cart object, so checkout is
 * a status change rather than a copy, and the warehouse sees the same record the
 * customer filled. The platform dictates the sequence this class follows:
 *
 *  - an Order must be inserted Draft with Pricebook2Id set before any OrderItem
 *    can be attached;
 *  - an OrderItem needs PricebookEntryId, Quantity and UnitPrice together;
 *  - once the order leaves Draft its lines are frozen, which is exactly the
 *    CART_NOT_EDITABLE rule the API publishes.
 *
 * Every read is bulk-safe: quantities are merged per product first, then one
 * query resolves all prices and stock. Nothing queries or writes inside a loop.
 *
 * with sharing + user-mode SOQL and DML: the integration identity gets what the
 * abc_API_Integration permission set grants it, and nothing more.
 */
public with sharing class abc_CartService {
    private static final String CLASS_NAME = 'abc_CartService';

    public static final String STATUS_DRAFT = 'Draft';
    public static final String STATUS_ACTIVATED = 'Activated';
    public static final String CHANNEL_IONIC = 'Ionic App';

    /** A mobile cart is not a data-loading tool. */
    private static final Integer MAX_ITEMS_PER_REQUEST = 100;
    private static final Integer MAX_QUANTITY_PER_LINE = 9999;

    private static final Pattern EMAIL_PATTERN = Pattern.compile(
        '^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$'
    );

    // --------------------------------------------------------------- commands

    /**
     * POST /abc/v1/carts - find or create the customer, then open a Draft order
     * stamped as coming from the Ionic app, optionally pre-filled with items.
     */
    public static abc_ApiModels.CartDto createCart(abc_ApiModels.CreateCartRequest request) {
        if (request == null) {
            throw abc_ApiException.invalidInput('A JSON request body is required.', 'body');
        }

        Contact customer = resolveCustomer(request.customer);
        Map<Id, Decimal> quantityByProduct = mergeRequestedItems(request.items);
        Map<Id, PricebookEntry> entryByProduct = loadEntries(quantityByProduct.keySet());
        assertStock(quantityByProduct, entryByProduct, new Map<Id, Decimal>());

        Order cart = new Order(
            AccountId = customer.AccountId,
            BillToContactId = customer.Id,
            Status = STATUS_DRAFT,
            EffectiveDate = Date.today(),
            abc_Order_Date__c = Date.today(),
            abc_Channel__c = CHANNEL_IONIC,
            Pricebook2Id = abc_ProductService.standardPricebookId()
        );
        insertRecords(new List<SObject>{ cart });

        if (!quantityByProduct.isEmpty()) {
            List<SObject> lines = new List<SObject>();
            for (Id productId : quantityByProduct.keySet()) {
                PricebookEntry entry = entryByProduct.get(productId);
                lines.add(
                    new OrderItem(
                        OrderId = cart.Id,
                        PricebookEntryId = entry.Id,
                        Quantity = quantityByProduct.get(productId),
                        UnitPrice = entry.UnitPrice
                    )
                );
            }
            insertRecords(lines);
        }

        abc_Logger.info(CLASS_NAME, 'createCart', 'Cart ' + cart.Id + ' opened for contact ' + customer.Id + '.');
        return toDto(loadCart(cart.Id));
    }

    /** GET /abc/v1/carts/{cartId} */
    public static abc_ApiModels.CartDto getCart(String cartId) {
        return toDto(loadCart(cartId));
    }

    /**
     * POST /abc/v1/carts/{cartId}/items - adding a product already in the cart
     * raises the quantity of the existing line instead of creating a second one,
     * so the cart always holds one line per product.
     */
    public static abc_ApiModels.CartDto addItem(String cartId, abc_ApiModels.AddItemRequest request) {
        if (request == null) {
            throw abc_ApiException.invalidInput('A JSON request body is required.', 'body');
        }

        Order cart = loadCart(cartId);
        assertEditable(cart);

        Id productId = toProductId(request.productId);
        Decimal quantity = validQuantity(request.quantity);
        Map<Id, PricebookEntry> entryByProduct = loadEntries(new Set<Id>{ productId });

        OrderItem existingLine = null;
        Map<Id, Decimal> alreadyInCart = new Map<Id, Decimal>();
        for (OrderItem line : itemsOf(cart)) {
            if (line.Product2Id == productId) {
                existingLine = line;
                alreadyInCart.put(productId, line.Quantity);
            }
        }

        // Stock is checked against what the cart would hold after the merge.
        assertStock(new Map<Id, Decimal>{ productId => quantity }, entryByProduct, alreadyInCart);

        if (existingLine == null) {
            PricebookEntry entry = entryByProduct.get(productId);
            insertRecords(
                new List<SObject>{
                    new OrderItem(
                        OrderId = cart.Id,
                        PricebookEntryId = entry.Id,
                        Quantity = quantity,
                        UnitPrice = entry.UnitPrice
                    )
                }
            );
        } else {
            updateRecords(
                new List<SObject>{ new OrderItem(Id = existingLine.Id, Quantity = existingLine.Quantity + quantity) }
            );
        }

        return toDto(loadCart(cart.Id));
    }

    /**
     * POST /abc/v1/carts/{cartId}/checkout - the cart becomes a real order.
     * EffectiveDate is pulled forward when needed so a cart opened on an earlier
     * day cannot trip the "effective date before order date" validation rule.
     */
    public static abc_ApiModels.CartDto checkout(String cartId) {
        Order cart = loadCart(cartId);
        assertEditable(cart);

        if (itemsOf(cart).isEmpty()) {
            throw abc_ApiException.validationError('An empty cart cannot be checked out.', 'items');
        }

        Order activation = new Order(Id = cart.Id, Status = STATUS_ACTIVATED, abc_Order_Date__c = Date.today());
        if (cart.EffectiveDate == null || cart.EffectiveDate < Date.today()) {
            activation.EffectiveDate = Date.today();
        }
        updateRecords(new List<SObject>{ activation });

        abc_Logger.info(CLASS_NAME, 'checkout', 'Cart ' + cart.Id + ' checked out.');
        return toDto(loadCart(cart.Id));
    }

    // -------------------------------------------------------------- customers

    /**
     * Email is the Ionic app's identity for a customer: an existing Contact with
     * that address is reused, otherwise an Account named "First Last" and its
     * Contact are created together.
     */
    private static Contact resolveCustomer(abc_ApiModels.CustomerRequest requested) {
        if (requested == null) {
            throw abc_ApiException.invalidInput('customer is required.', 'customer');
        }
        if (String.isBlank(requested.email)) {
            throw abc_ApiException.invalidInput('customer.email is required.', 'customer.email');
        }
        String email = requested.email.trim();
        if (!EMAIL_PATTERN.matcher(email).matches()) {
            throw abc_ApiException.invalidInput('customer.email is not a valid email address.', 'customer.email');
        }
        if (String.isBlank(requested.lastName)) {
            throw abc_ApiException.invalidInput('customer.lastName is required.', 'customer.lastName');
        }

        List<Contact> existing = [
            SELECT Id, AccountId, Email, Name
            FROM Contact
            WHERE Email = :email AND AccountId != NULL
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0];
        }

        String firstName = String.isBlank(requested.firstName) ? null : requested.firstName.trim();
        String lastName = requested.lastName.trim();

        Account account = new Account(Name = firstName == null ? lastName : firstName + ' ' + lastName);
        insertRecords(new List<SObject>{ account });

        Contact contact = new Contact(
            AccountId = account.Id,
            FirstName = firstName,
            LastName = lastName,
            Email = email,
            Phone = String.isBlank(requested.phone) ? null : requested.phone.trim()
        );
        insertRecords(new List<SObject>{ contact });
        return contact;
    }

    // ------------------------------------------------------------ cart access

    private static Order loadCart(String cartId) {
        Id orderId = toOrderId(cartId);
        List<Order> carts = [
            SELECT
                Id,
                OrderNumber,
                Status,
                EffectiveDate,
                TotalAmount,
                CreatedDate,
                AccountId,
                BillToContactId,
                Account.Name,
                BillToContact.Name,
                BillToContact.Email,
                (
                    SELECT Id, Product2Id, Product2.Name, Quantity, UnitPrice, TotalPrice
                    FROM OrderItems
                    ORDER BY Product2.Name ASC
                )
            FROM Order
            WHERE Id = :orderId
            WITH USER_MODE
        ];
        if (carts.isEmpty()) {
            throw abc_ApiException.cartNotFound('No cart exists with id ' + cartId + '.');
        }
        return carts[0];
    }

    private static List<OrderItem> itemsOf(Order cart) {
        return cart.OrderItems == null ? new List<OrderItem>() : cart.OrderItems;
    }

    private static void assertEditable(Order cart) {
        if (cart.Status != STATUS_DRAFT) {
            throw abc_ApiException.cartNotEditable(
                'Cart ' + cart.OrderNumber + ' has status "' + cart.Status + '" and can no longer be changed.'
            );
        }
    }

    // -------------------------------------------------------------- catalogue

    /** Merges repeated products so one request can never create two lines for one product. */
    private static Map<Id, Decimal> mergeRequestedItems(List<abc_ApiModels.CartItemRequest> items) {
        Map<Id, Decimal> quantityByProduct = new Map<Id, Decimal>();
        if (items == null || items.isEmpty()) {
            return quantityByProduct;
        }
        if (items.size() > MAX_ITEMS_PER_REQUEST) {
            throw abc_ApiException.invalidInput(
                'A cart request may contain at most ' + MAX_ITEMS_PER_REQUEST + ' items.',
                'items'
            );
        }
        for (abc_ApiModels.CartItemRequest item : items) {
            if (item == null) {
                throw abc_ApiException.invalidInput('items contains an empty entry.', 'items');
            }
            Id productId = toProductId(item.productId);
            Decimal quantity = validQuantity(item.quantity);
            Decimal running = quantityByProduct.containsKey(productId) ? quantityByProduct.get(productId) : 0;
            quantityByProduct.put(productId, running + quantity);
        }
        return quantityByProduct;
    }

    /** One query for every requested product; a product without an active standard price is not sellable. */
    private static Map<Id, PricebookEntry> loadEntries(Set<Id> productIds) {
        Map<Id, PricebookEntry> entryByProduct = new Map<Id, PricebookEntry>();
        if (productIds == null || productIds.isEmpty()) {
            return entryByProduct;
        }
        Id pricebookId = abc_ProductService.standardPricebookId();
        for (PricebookEntry entry : [
            SELECT Id, UnitPrice, Product2Id, Product2.Name, Product2.abc_Stock_Quantity__c
            FROM PricebookEntry
            WHERE
                Pricebook2Id = :pricebookId
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND Product2Id IN :productIds
            WITH USER_MODE
        ]) {
            entryByProduct.put(entry.Product2Id, entry);
        }
        for (Id productId : productIds) {
            if (!entryByProduct.containsKey(productId)) {
                throw abc_ApiException.productNotFound(
                    'Product ' + productId + ' is not available in the ABC catalogue.'
                );
            }
        }
        return entryByProduct;
    }

    private static void assertStock(
        Map<Id, Decimal> requested,
        Map<Id, PricebookEntry> entryByProduct,
        Map<Id, Decimal> alreadyInCart
    ) {
        for (Id productId : requested.keySet()) {
            PricebookEntry entry = entryByProduct.get(productId);
            Decimal stock = entry.Product2.abc_Stock_Quantity__c == null ? 0 : entry.Product2.abc_Stock_Quantity__c;
            Decimal inCart = alreadyInCart.containsKey(productId) ? alreadyInCart.get(productId) : 0;
            Decimal wanted = requested.get(productId) + inCart;
            if (stock < wanted) {
                throw abc_ApiException.insufficientStock(
                    'Only ' +
                        String.valueOf(stock.setScale(0)) +
                        ' unit(s) of "' +
                        entry.Product2.Name +
                        '" are in stock; the cart would hold ' +
                        String.valueOf(wanted.setScale(0)) +
                        '.'
                );
            }
        }
    }

    // ------------------------------------------------------------- validation

    private static Id toProductId(String value) {
        if (String.isBlank(value)) {
            throw abc_ApiException.invalidInput('productId is required.', 'productId');
        }
        Id productId;
        try {
            productId = Id.valueOf(value.trim());
        } catch (Exception parseFailure) {
            throw abc_ApiException.productNotFound('"' + value + '" is not a product id.');
        }
        if (productId.getSobjectType() != Product2.SObjectType) {
            throw abc_ApiException.productNotFound('"' + value + '" is not a product id.');
        }
        return productId;
    }

    private static Id toOrderId(String cartId) {
        if (String.isBlank(cartId)) {
            throw abc_ApiException.cartNotFound('A cart id is required.');
        }
        Id orderId;
        try {
            orderId = Id.valueOf(cartId.trim());
        } catch (Exception parseFailure) {
            throw abc_ApiException.cartNotFound('No cart exists with id ' + cartId + '.');
        }
        if (orderId.getSobjectType() != Order.SObjectType) {
            throw abc_ApiException.cartNotFound('No cart exists with id ' + cartId + '.');
        }
        return orderId;
    }

    private static Decimal validQuantity(Decimal quantity) {
        if (quantity == null) {
            throw abc_ApiException.invalidInput('quantity is required.', 'quantity');
        }
        if (quantity <= 0) {
            throw abc_ApiException.validationError('quantity must be greater than zero.', 'quantity');
        }
        if (quantity != quantity.setScale(0, System.RoundingMode.DOWN)) {
            throw abc_ApiException.validationError('quantity must be a whole number of units.', 'quantity');
        }
        if (quantity > MAX_QUANTITY_PER_LINE) {
            throw abc_ApiException.validationError(
                'quantity may not exceed ' + MAX_QUANTITY_PER_LINE + ' units per product.',
                'quantity'
            );
        }
        return quantity;
    }

    // --------------------------------------------------------------- plumbing

    private static void insertRecords(List<SObject> records) {
        try {
            Database.insert(records, AccessLevel.USER_MODE);
        } catch (DmlException failure) {
            throw translate(failure);
        }
    }

    private static void updateRecords(List<SObject> records) {
        try {
            Database.update(records, AccessLevel.USER_MODE);
        } catch (DmlException failure) {
            throw translate(failure);
        }
    }

    /**
     * A validation rule or a required field is the caller's problem (400); a
     * missing permission is ours, so it stays an unhandled fault and surfaces as
     * a logged 500 rather than blaming the Ionic developer.
     */
    private static Exception translate(DmlException failure) {
        if (failure.getNumDml() == 0) {
            return failure;
        }
        String statusCode = failure.getDmlStatusCode(0);
        if (statusCode != null && statusCode.startsWith('INSUFFICIENT_ACCESS')) {
            return failure;
        }
        List<String> fields = failure.getDmlFieldNames(0);
        String fieldName = fields == null || fields.isEmpty() ? null : fields[0];
        return abc_ApiException.validationError(failure.getDmlMessage(0), fieldName);
    }

    // ------------------------------------------------------------------- DTOs

    private static abc_ApiModels.CartDto toDto(Order cart) {
        abc_ApiModels.CartDto dto = new abc_ApiModels.CartDto();
        dto.cartId = cart.Id;
        dto.orderNumber = cart.OrderNumber;
        dto.status = cart.Status;
        dto.createdDate = cart.CreatedDate;

        abc_ApiModels.CustomerDto customer = new abc_ApiModels.CustomerDto();
        customer.accountId = cart.AccountId;
        customer.contactId = cart.BillToContactId;
        customer.email = cart.BillToContact == null ? null : cart.BillToContact.Email;
        customer.name = cart.BillToContact == null
            ? (cart.Account == null ? null : cart.Account.Name)
            : cart.BillToContact.Name;
        dto.customer = customer;

        Decimal total = 0;
        for (OrderItem line : itemsOf(cart)) {
            abc_ApiModels.CartItemDto item = new abc_ApiModels.CartItemDto();
            item.itemId = line.Id;
            item.productId = line.Product2Id;
            item.productName = line.Product2 == null ? null : line.Product2.Name;
            item.quantity = line.Quantity;
            item.unitPrice = line.UnitPrice;
            item.totalPrice = line.TotalPrice == null ? line.Quantity * line.UnitPrice : line.TotalPrice;
            total += item.totalPrice;
            dto.items.add(item);
        }
        dto.totalAmount = total.setScale(2);
        return dto;
    }
}
