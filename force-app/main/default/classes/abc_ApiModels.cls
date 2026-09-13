/**
 * The wire contract of the ABC REST API, in one place.
 *
 * Request classes are the targets of JSON.deserializeStrict: every field the
 * Ionic app is allowed to send is declared here and nothing else, so an
 * unexpected attribute is rejected as MALFORMED_JSON instead of being silently
 * ignored. DTO classes are what gets serialised back into the envelope's data
 * member; the services never hand raw SObjects to the client.
 *
 * "limit" is an Apex reserved word, so the product page exposes itself through
 * toPayload() where the JSON keys are free of Apex naming rules.
 */
public class abc_ApiModels {
    // ------------------------------------------------------------- requests

    /** The person the cart belongs to. Matched to a Contact by email. */
    public class CustomerRequest {
        public String email;
        public String firstName;
        public String lastName;
        public String phone;
    }

    /** A line requested at cart creation time. */
    public class CartItemRequest {
        public String productId;
        public Decimal quantity;
    }

    /** Body of POST /abc/v1/carts. */
    public class CreateCartRequest {
        public CustomerRequest customer;
        public List<CartItemRequest> items;
    }

    /** Body of POST /abc/v1/carts/{cartId}/items. */
    public class AddItemRequest {
        public String productId;
        public Decimal quantity;
    }

    // ----------------------------------------------------------------- DTOs

    public class ProductDto {
        public String id;
        public String name;
        public String productCode;
        public String description;
        public String category;
        public Boolean requiresPrescription;
        public Decimal stockQuantity;
        public Decimal unitPrice;
        public String currencyIsoCode;
    }

    /** One page of the catalogue. count is the number of items in this page. */
    public class ProductListDto {
        public List<ProductDto> items = new List<ProductDto>();
        public Integer count = 0;
        public Integer pageSize;
        public Integer pageOffset;

        /** JSON shape of data for GET /abc/v1/products. */
        public Map<String, Object> toPayload() {
            return new Map<String, Object>{
                'items' => items,
                'count' => count,
                'limit' => pageSize,
                'offset' => pageOffset
            };
        }
    }

    public class CustomerDto {
        public String accountId;
        public String contactId;
        public String email;
        public String name;
    }

    public class CartItemDto {
        public String itemId;
        public String productId;
        public String productName;
        public Decimal quantity;
        public Decimal unitPrice;
        public Decimal totalPrice;
    }

    /** The cart, i.e. the Order, exactly as the Ionic app sees it. */
    public class CartDto {
        public String cartId;
        public String orderNumber;
        public String status;
        public CustomerDto customer;
        public List<CartItemDto> items = new List<CartItemDto>();
        public Decimal totalAmount = 0;
        public Datetime createdDate;
    }
}
