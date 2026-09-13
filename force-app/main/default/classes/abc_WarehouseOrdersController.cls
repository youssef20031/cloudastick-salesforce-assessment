/**
 * Controller for the ABC warehouse orders console (abc_WarehouseOrders.page).
 *
 * The warehouse operator opens one screen, sees every order with its number,
 * status and effective date, and expands a row to read the products that have
 * to be picked. This class does the reading; the page does the presenting.
 *
 * ---------------------------------------------------------------------------
 * ICON PRECEDENCE - the design decision this class exists to make explicit
 * ---------------------------------------------------------------------------
 * The assessment asks for four icons, and the four rules overlap: an order that
 * is "Delivered" was also created on some day, so both a status rule and a date
 * rule match the same record. Nothing in the requirement says which one wins,
 * so the choice is made here, once, and stated on the page in a legend:
 *
 *   1. Status = 'Delivered'            -> &#x2705;  white heavy check mark
 *   2. Status = 'In delivery'          -> &#x1F69A; delivery truck
 *   3. CreatedDate falls on today      -> &#x23F3;  hourglass with flowing sand
 *   4. anything else (created earlier) -> &#x231B;  hourglass done
 *
 * Status beats date because of what the operator uses the list for: fulfilment
 * state is the actionable signal ("is this mine to pick, is it on the road, is
 * it finished") while the age of the order is only context. An order delivered
 * this morning is finished business, and showing it as "created today" would
 * hide that. The rule is total and mutually exclusive, so every row gets
 * exactly one icon.
 *
 * The emoji are emitted as HTML numeric character entities rather than literal
 * characters. Visualforce markup, the Metadata API and the file encodings in
 * between all handle plain ASCII entities without surprises, while a literal
 * astral-plane character such as the truck can survive or not survive a round
 * trip depending on the tool that touched the file last. Each icon is paired
 * with a visible status column and an aria-label, so the icon is never the only
 * carrier of meaning.
 *
 * ---------------------------------------------------------------------------
 * Row cap
 * ---------------------------------------------------------------------------
 * apex:repeat renders at most 1000 items, so the query is capped at 1000 and
 * ordered newest-first. When the cap is reached the page says so rather than
 * silently truncating the warehouse's work list.
 */
public with sharing class abc_WarehouseOrdersController {
    private static final String CLASS_NAME = 'abc_WarehouseOrdersController';

    /** Order.Status values that carry an icon of their own (both Activated-coded). */
    public static final String STATUS_IN_DELIVERY = 'In delivery';
    public static final String STATUS_DELIVERED = 'Delivered';

    /** Stable keys for the four outcomes. Tests and the page assert on these, not on the emoji. */
    public static final String ICON_DELIVERED = 'delivered';
    public static final String ICON_IN_DELIVERY = 'inDelivery';
    public static final String ICON_CREATED_TODAY = 'createdToday';
    public static final String ICON_CREATED_PAST = 'createdPast';

    /** HTML numeric character entities - see the class comment for why. */
    public static final String ENTITY_DELIVERED = '&#x2705;';
    public static final String ENTITY_IN_DELIVERY = '&#x1F69A;';
    public static final String ENTITY_CREATED_TODAY = '&#x23F3;';
    public static final String ENTITY_CREATED_PAST = '&#x231B;';

    /** apex:repeat renders no more than 1000 items, so the query stops there too. */
    public static final Integer MAX_ROWS = 1000;

    private static final Map<String, String> ICON_ENTITIES = new Map<String, String>{
        ICON_DELIVERED => ENTITY_DELIVERED,
        ICON_IN_DELIVERY => ENTITY_IN_DELIVERY,
        ICON_CREATED_TODAY => ENTITY_CREATED_TODAY,
        ICON_CREATED_PAST => ENTITY_CREATED_PAST
    };

    private static final Map<String, String> ICON_LABELS = new Map<String, String>{
        ICON_DELIVERED => 'Delivered',
        ICON_IN_DELIVERY => 'In delivery',
        ICON_CREATED_TODAY => 'Created today',
        ICON_CREATED_PAST => 'Created before today'
    };

    private static final String MSG_NO_ACCESS =
        'You do not have permission to read orders. Ask an administrator for the "abc Warehouse User" permission set.';
    private static final String MSG_QUERY_FAILED =
        'The order list could not be loaded. The error has been logged - please retry, and quote the time of day if it keeps happening.';

    /**
     * Test seams. The two failure paths below cannot be reached from a passing
     * org (an administrator always reads orders, and a well-formed SOQL string
     * does not fail on demand), so the tests switch them on deliberately.
     */
    @TestVisible
    private static Boolean testForceNoAccess = false;
    @TestVisible
    private static Exception testInjectedFailure = null;

    /**
     * The page renders without an apex:form, so there is no view state to keep
     * small - but the data is still held transient and rebuilt per request so
     * that up to 1000 orders and their line items never end up serialised.
     */
    private transient List<OrderRow> rows;
    private transient Boolean errorFlag = false;
    private transient String errorText;

    public abc_WarehouseOrdersController() {
        // Load eagerly: apex:pageMessages renders near the top of the page, so
        // any error message has to exist before rendering starts.
        ensureLoaded();
    }

    // ------------------------------------------------------------------ page API

    /** Every order the running user may see, newest first, capped at MAX_ROWS. */
    public List<OrderRow> getRows() {
        ensureLoaded();
        return rows;
    }

    public Integer getOrderCount() {
        ensureLoaded();
        return rows.size();
    }

    public Boolean getHasOrders() {
        ensureLoaded();
        return !rows.isEmpty();
    }

    /** True when the query filled the cap, i.e. older orders exist but are not shown. */
    public Boolean getRowLimitReached() {
        ensureLoaded();
        return rows.size() >= MAX_ROWS;
    }

    public Boolean getHasError() {
        ensureLoaded();
        return errorFlag == true;
    }

    public String getErrorMessage() {
        ensureLoaded();
        return errorText;
    }

    public Integer getMaxRows() {
        return MAX_ROWS;
    }

    // ------------------------------------------------------------------- loading

    private void ensureLoaded() {
        if (rows != null) {
            return;
        }
        load();
    }

    private void load() {
        rows = new List<OrderRow>();
        errorFlag = false;
        errorText = null;
        abc_Logger.setSource(abc_Logger.SOURCE_VISUALFORCE);

        try {
            if (testForceNoAccess == true || !Schema.SObjectType.Order.isAccessible()) {
                fail(ApexPages.Severity.WARNING, MSG_NO_ACCESS);
                abc_Logger.warn(CLASS_NAME, 'load', 'Order is not readable for ' + UserInfo.getUserName());
                return;
            }

            Integer index = 0;
            for (Order item : queryOrders()) {
                rows.add(new OrderRow(item, index));
                index++;
            }
        } catch (Exception e) {
            rows = new List<OrderRow>();
            fail(ApexPages.Severity.ERROR, MSG_QUERY_FAILED);
            abc_Logger.error(CLASS_NAME, 'load', 'Warehouse order query failed', e);
        } finally {
            abc_Logger.flush();
        }
    }

    /**
     * One query, one subquery: the line items travel with their order so that
     * expanding a row costs nothing and the page never fires a query per row.
     */
    @TestVisible
    private List<Order> queryOrders() {
        if (testInjectedFailure != null) {
            throw testInjectedFailure;
        }
        return [
            SELECT
                Id,
                OrderNumber,
                Status,
                EffectiveDate,
                CreatedDate,
                TotalAmount,
                Account.Name,
                (SELECT Id, Product2.Name, Quantity, UnitPrice, TotalPrice FROM OrderItems ORDER BY Product2.Name)
            FROM Order
            ORDER BY CreatedDate DESC
            LIMIT 1000
        ];
    }

    private void fail(ApexPages.Severity severity, String message) {
        errorFlag = true;
        errorText = message;
        ApexPages.addMessage(new ApexPages.Message(severity, message));
    }

    // --------------------------------------------------------------- icon rules

    /**
     * The precedence rule from the class comment, in one place so that the page,
     * the tests and the documentation cannot drift apart.
     *
     * @param status      Order.Status as stored on the record.
     * @param createdDate Order.CreatedDate; null is treated as "not today".
     * @return one of ICON_DELIVERED, ICON_IN_DELIVERY, ICON_CREATED_TODAY, ICON_CREATED_PAST.
     */
    public static String resolveIconKey(String status, Datetime createdDate) {
        if (STATUS_DELIVERED.equalsIgnoreCase(status)) {
            return ICON_DELIVERED;
        }
        if (STATUS_IN_DELIVERY.equalsIgnoreCase(status)) {
            return ICON_IN_DELIVERY;
        }
        // Datetime.date() converts to the running user's time zone, which is the
        // same zone Date.today() answers in, so "today" means the operator's today.
        if (createdDate != null && createdDate.date() == Date.today()) {
            return ICON_CREATED_TODAY;
        }
        return ICON_CREATED_PAST;
    }

    /** HTML numeric character entity for an icon key. */
    public static String iconEntityFor(String iconKey) {
        String entity = ICON_ENTITIES.get(iconKey);
        return entity == null ? ENTITY_CREATED_PAST : entity;
    }

    /** Human-readable label for an icon key, used as title and aria-label. */
    public static String iconLabelFor(String iconKey) {
        String label = ICON_LABELS.get(iconKey);
        return label == null ? ICON_LABELS.get(ICON_CREATED_PAST) : label;
    }

    // ------------------------------------------------------------- row wrapper

    /**
     * One table row: the order, the products inside it, and everything the
     * markup needs pre-computed so the page stays free of logic.
     */
    public class OrderRow {
        public Order orderRecord { get; private set; }
        public List<OrderItem> items { get; private set; }

        public String iconKey { get; private set; }
        public String iconEntity { get; private set; }
        public String iconLabel { get; private set; }

        /** DOM id of the hidden detail row, referenced by the toggle's aria-controls. */
        public String detailId { get; private set; }

        public String orderNumber { get; private set; }
        public String status { get; private set; }
        public String accountName { get; private set; }
        public String effectiveDateText { get; private set; }
        public String createdDateText { get; private set; }
        public String totalAmountText { get; private set; }

        public OrderRow(Order source, Integer index) {
            this.orderRecord = source;
            // A subquery with no children comes back as null, not as an empty list.
            this.items = source.OrderItems == null ? new List<OrderItem>() : source.OrderItems;

            this.iconKey = resolveIconKey(source.Status, source.CreatedDate);
            this.iconEntity = iconEntityFor(this.iconKey);
            this.iconLabel = iconLabelFor(this.iconKey);

            this.detailId = 'abc-order-detail-' + index;
            this.orderNumber = String.isBlank(source.OrderNumber) ? '(no number)' : source.OrderNumber;
            this.status = source.Status;
            this.accountName = source.Account == null ? '' : source.Account.Name;
            this.effectiveDateText = source.EffectiveDate == null ? '' : source.EffectiveDate.format();
            this.createdDateText = source.CreatedDate == null ? '' : source.CreatedDate.format('d MMM yyyy, HH:mm');
            this.totalAmountText = formatMoney(source.TotalAmount);
        }

        /**
         * Money always reads with two decimal places. Decimal.format() is locale
         * aware but will happily render a whole amount as "0" or "12", which makes
         * a column of totals ragged and hard to scan. Building the string from a
         * scaled Decimal keeps every row aligned and is not locale dependent.
         */
        private String formatMoney(Decimal value) {
            Decimal scaled = (value == null ? 0 : value).setScale(2, System.RoundingMode.HALF_UP);
            return String.valueOf(scaled);
        }

        public Boolean getHasItems() {
            return !items.isEmpty();
        }

        public Integer getItemCount() {
            return items.size();
        }

        /** Screen-reader sentence for the expand button, so the caret is never the only cue. */
        public String getToggleLabel() {
            return 'Show the ' + items.size() + ' product line(s) in order ' + orderNumber;
        }
    }
}
