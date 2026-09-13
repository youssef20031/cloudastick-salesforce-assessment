# Plan: Cloudastick Salesforce Entry Assessment (Pharmacy ABC)

## 1. Context

`E:\cloudastick` contains only the assessment PDF (`Salesforce Entry Assessment .docx (1).pdf`). Cloudastick Systems asks for a Salesforce Developer Edition build for pharmacy "ABC":

- Data model for customers, products, orders; a custom Lightning app to manage them.
- Apex REST endpoints for an Ionic app: retrieve product list; create a shopping cart and add products to it. Error handling + logging best practices; API docs for the Ionic developers.
- Visualforce page for the warehouse user: all orders with order number, status, effective date; icon before the order number (⏳ created today, ⌛ created in the past, 🚚 status "In delivery", ✅ status "Delivered"); each row expandable to show product name, quantity, unit price.
- Batch Apex: orders with status "Delivered" and Order Date older than one year are archived into a Big Object.
- Every new API name (field/object/class/etc.) must contain `abc`.
- Deliverables: reviewer System Administrator user (email `assessments@cloudastick.com`, Salesforce license), Postman collection, professional solution documentation (Apex components, ERD + data model + design decisions, Salesforce features with rationale).

**Decisions made with the user**
- Fresh Developer Edition org (none exists yet). Deadline: **today** → required items first, extras last and droppable.
- Data model: **standard objects + `abc_` custom fields** (Account/Contact, Product2/PricebookEntry, Order/OrderItem). Cart = Order in Draft status. Confirmed even after the license finding below.
- Scope: assessment-plus (permission sets, validation rules, one record-triggered Flow, platform-event logging, stock quantity).
- Docs: Markdown in repo + PDF export. Repo: local git → **private GitHub repo** (gh CLI is authenticated as `youssef20031`).

**Local environment (verified)**: Node v25.8 (nvm4w), Git 2.55, VS Code, Java 25, Python 3.14, Chrome + Edge, GitHub CLI (authed), Postman installed. Salesforce CLI **not** installed. No pandoc/mmdc.

## 2. Verified constraints that shape the design (from research, Sept 2026 docs)

| # | Fact | Consequence |
|---|------|-------------|
| C1 | `@salesforce/cli` breaks on Node 25 (non-LTS); supported = Active LTS (Node 24). Don't run `sf` from Git Bash. | `nvm install 24 && nvm use 24` before installing the CLI; run `sf` in PowerShell. |
| C2 | Connected App creation is disabled by default in orgs created since Spring '26; username-password OAuth flow is blocked/retiring. | API auth = **External Client App (ECA)** + **OAuth 2.0 client-credentials flow** with a run-as user. Created in Setup UI (consumer key/secret are revealed after an identity-verification email code). |
| C3 | Developer Edition has **2 Salesforce licenses** (admin + reviewer) and 3 Salesforce Platform licenses; Platform users **cannot** access Order/OrderItem/Product2/PricebookEntry. | Warehouse role = permission set `abc_Warehouse_User` (assigned to the reviewer for demo). ECA run-as user = the admin user (or the single "Salesforce Integration" license if Company Information shows one). Document as a DE limitation. |
| C4 | Order must be inserted with a Draft-coded Status; custom statuses "In delivery"/"Delivered" must map to StatusCode **Activated**. Activated orders: products can be edited but not added/removed; order **cannot be deleted** until Status is set back to a Draft-coded value (needs "Edit Activated Orders" permission; activation needs "Activate Orders"). `Pricebook2Id` must be set before adding OrderItems; OrderItem needs `PricebookEntryId`, `Quantity`, `UnitPrice`. | Cart = Draft Order with `Pricebook2Id` = standard price book. Checkout = Status → Activated. Archive batch: set Status = Draft, then delete. Statuses deployed via `standardValueSets/OrderStatus.standardValueSet-meta.xml` using `<groupingStringEnum>OrderStatusCode</groupingStringEnum>` and per-value `<groupingString>Activated</groupingString>` (include Draft + Activated, the deploy replaces the whole list). If the deploy is rejected, add both values in Setup (Status Category = Activated) and retrieve. Verify with `SELECT Status, StatusCode FROM Order` after seeding. Any record with a non-Draft status must be **inserted as Draft with items, then updated**. |
| C5 | Big objects: field types only DateTime, Email, Lookup, Number, Phone, Text, LongTextArea, URL (**no Date**); index = 1–5 required fields, ≤100 text chars, **immutable after deploy**; `Database.insertImmediate()` only (idempotent upsert on index, returns SaveResult, **treated as a callout** → must run before any sObject DML or `EventBus.publish` in the same transaction or it throws "uncommitted work pending"); **test DML on big objects is not rolled back** and mixed big-object + sObject DML in a test fails; SOQL must filter index fields in order (no aggregates, no `!=`/`LIKE`). | `abc_Order_Archive__b` with DateTime fields; index `[abc_Order_Date__c DESC, abc_Order_Number__c ASC]` fixed before first deploy; batch `execute()` order = archive first, then deactivate + delete, then `abc_Logger.flush()` last; batch writes through an injectable `abc_IOrderArchiver` so tests use a fake; verify archive rows with anonymous-Apex SOQL. |
| C6 | Platform event with `publishBehavior = PublishImmediately` is delivered even when the transaction rolls back. `Request.getCurrent().getRequestId()` gives a correlation id. | Logging = `abc_Log_Event__e` (PublishImmediately) → trigger → `abc_Log__c`; every API error response carries `requestId`. |
| C7 | Visualforce: emoji safest as HTML numeric entities (`&#x23F3;` ⏳, `&#x231B;` ⌛, `&#x1F69A;` 🚚, `&#x2705;` ✅); SLDS via `<apex:slds/>` inside `slds-scope`; `apex:repeat` ≤1000 items; page needs `availableInTouch=true` for Lightning; VF tab = `CustomTab` with `<page>`. | Custom controller + `apex:repeat` table + plain-JS row toggle; `LIMIT 1000` ordered by CreatedDate DESC. |
| C8 | Reviewer user via `sf data create record -s User ...`; no credentials email is sent by API → use `System.resetPassword(userId, true)` (emails a reset link, valid 24 h). Username must be globally unique. | Create the user early (Phase 1) so the license and permission sets are in place; send the reset email only at hand-in (Phase 8). |
| C9 | Product2 has no stock field; standard price book must be active; tests use `Test.getStandardPricebookId()`. | `Product2.abc_Stock_Quantity__c`; seed script activates the standard price book and creates PBEs. |
| C10 | The ⌛ rule keys on `CreatedDate`, and every seeded order is created today. Backdating needs Setup → User Interface → "Set Audit Fields upon Record Creation" plus the `CreateAuditFields` user permission; then Apex/API inserts may set `CreatedDate`. | Enable the setting in Phase 1 (user at keyboard), add `CreateAuditFields` to `abc_Pharmacy_Admin`, seed past orders with an explicit `CreatedDate`. Fallback: the reviewer sees ⌛ naturally on any day after seeding. |

## 3. Solution design

### 3.1 Data model (ERD to be drawn in Mermaid in the docs)

Standard: **Account** (customer; one per person/household) ─1:n─ **Contact** (person, email = API identity). **Pricebook2** (standard price book only) ─1:n─ **PricebookEntry** ─n:1─ **Product2**; PricebookEntry ─1:n─ **OrderItem** ─n:1─ **Order** ─n:1─ Account (`BillToContactId` → Contact, `Pricebook2Id` → Pricebook2). **User** (lookup from the log). Custom: **abc_Order_Archive__b** (big object, snapshot of archived orders incl. serialized line items), **abc_Log__c** (persisted log), **abc_Log_Event__e** (platform event). All nine appear in the docs' object list.

Custom fields (all `abc_`-prefixed):
- `Product2`: `abc_Stock_Quantity__c` (Number 18,0, default 0), `abc_Requires_Prescription__c` (Checkbox), `abc_Category__c` (Picklist: Medicine, Supplement, Personal Care, Medical Device).
- `Order`: `abc_Order_Date__c` (Date, default `TODAY()`; the "Order Date" the batch uses), `abc_Delivered_Date__c` (Date), `abc_Channel__c` (Picklist: Ionic App, Manual; default Manual).
- `Order.Status` values: Draft (Draft, default), Activated (Activated), In delivery (Activated), Delivered (Activated).
- `abc_Order_Archive__b`: `abc_Order_Date__c` DateTime req (index 1, DESC), `abc_Order_Number__c` Text(30) req (index 2, ASC), `abc_Order_Id__c` Text(18), `abc_Account_Id__c` Text(18), `abc_Account_Name__c` Text(255), `abc_Status__c` Text(40), `abc_Channel__c` Text(40), `abc_Effective_Date__c` DateTime, `abc_Delivered_Date__c` DateTime, `abc_Total_Amount__c` Number(16,2), `abc_Line_Items_JSON__c` LongTextArea(131072), `abc_Archived_On__c` DateTime. Index name `abc_Order_Archive_Index`.
- `abc_Log__c` (Name auto-number `LOG-{00000}`): `abc_Level__c` (Picklist DEBUG/INFO/WARN/ERROR), `abc_Message__c` (LongTextArea), `abc_Class__c`, `abc_Method__c`, `abc_Stack_Trace__c` (LongTextArea), `abc_Record_Id__c` (Text 18), `abc_Request_Id__c`, `abc_Quiddity__c`, `abc_Logged_By__c` (Lookup User), `abc_Timestamp__c` (DateTime), `abc_Http_Status__c` (Number 3,0), `abc_Source__c` (Picklist REST/Batch/Trigger/Visualforce/Other).
- `abc_Log_Event__e` (HighVolume, PublishImmediately): same fields as text/number/datetime.

Validation rules: `Order.abc_Order_Date_Not_In_Future`, `Order.abc_Effective_Date_Not_Before_Order_Date`, `Product2.abc_Stock_Quantity_Not_Negative`.

Design decisions to write up: standard-first with `abc_` extensions; Account+Contact instead of Person Accounts (not enabled in DE by default, keeps model simple); cart = Draft Order (no separate cart object; activation = checkout, no data copy); single standard price book (one price per product); `abc_Order_Date__c` (placed) vs `EffectiveDate` (standard, "effective date" on the VF page); statuses mapped to Activated so fulfillment states lock line items; archive as one big-object row per order with line items as JSON (big objects have no master-detail, one row keeps the archive atomic and idempotent); index by date then number (browse archive by period, unique per order); platform-event logging survives rollbacks; DE license limitation (C3).

### 3.2 REST API (Apex REST, base `https://<MyDomain>.my.salesforce.com/services/apexrest`)

Envelope for every response: `{ "success": bool, "data": object|null, "errors": [{ "code": "...", "message": "...", "field": "..."? }], "requestId": "..." }`. Content-Type `application/json`. Status codes: 200, 201, 400 (`INVALID_INPUT`, `MALFORMED_JSON`, `VALIDATION_ERROR`), 404 (`CART_NOT_FOUND`, `PRODUCT_NOT_FOUND`, `ROUTE_NOT_FOUND`), 409 (`CART_NOT_EDITABLE`, `INSUFFICIENT_STOCK`), 500 (`INTERNAL_ERROR`, generic message, details only in `abc_Log__c`).

| Method + path | Purpose | Input | Output (`data`) |
|---|---|---|---|
| `GET /abc/v1/products` | Product list for Ionic | query: `search`, `category`, `includeOutOfStock` (default false), `limit` (≤200, default 50), `offset` | `{ items:[{id,name,productCode,description,category,requiresPrescription,stockQuantity,unitPrice,currencyIsoCode}], count, limit, offset }` |
| `POST /abc/v1/carts` | Create cart (Draft Order), find-or-create Contact by email (+Account "First Last") | body `{ customer:{email*,firstName,lastName*,phone}, items?:[{productId*,quantity*}] }` | 201 + `CartDto` |
| `POST /abc/v1/carts/{cartId}/items` | Add product to cart (merge quantity if product already in cart) | body `{ productId*, quantity* }` | 200 + `CartDto` |
| `GET /abc/v1/carts/{cartId}` | Read cart | – | 200 + `CartDto` |
| `POST /abc/v1/carts/{cartId}/checkout` (droppable extra) | Activate order (Status → Activated, `abc_Order_Date__c` = today) | – | 200 + `CartDto` |

`CartDto = { cartId, orderNumber, status, customer:{accountId,contactId,email,name}, items:[{itemId,productId,productName,quantity,unitPrice,totalPrice}], totalAmount, createdDate }`.

Rules: parse body with `JSON.deserializeStrict` into request classes (own error shape, C2 research); validate quantity > 0, product active + has active standard PBE, stock ≥ requested; cart must be Status Draft; one `@RestResource` class per URL prefix, so the single `@HttpPost` matches the route by regex on the suffix of `RestContext.request.requestURI` (tolerate the `/services/apexrest` prefix; unknown suffix → 404 `ROUTE_NOT_FOUND`); handlers are `global static void` and write status + body through `abc_RestResponse` (201 for create); `with sharing` services + `WITH USER_MODE` SOQL; every handler wrapped in try/catch → `abc_RestResponse` + `abc_Logger.flush()` in `finally`.

Auth: ECA label "abc Ionic App", API name `abc_Ionic_App` (Local, OAuth, scope `api`, client-credentials enabled, run-as = admin user with `abc_API_Integration` permission set). Token: `POST https://<MyDomain>.my.salesforce.com/services/oauth2/token` (My Domain host, not login.salesforce.com) with `grant_type=client_credentials&client_id&client_secret`. Docs note: production Ionic app should use Authorization Code + PKCE (per-user) or a backend proxy; client credentials is used here for reviewer simplicity.

### 3.3 Visualforce warehouse page

`abc_WarehouseOrders.page` + `abc_WarehouseOrdersController` (with sharing). Query: `SELECT Id, OrderNumber, Status, EffectiveDate, CreatedDate, TotalAmount, Account.Name, (SELECT Id, Product2.Name, Quantity, UnitPrice, TotalPrice FROM OrderItems ORDER BY Product2.Name) FROM Order ORDER BY CreatedDate DESC LIMIT 1000`. Row wrapper exposes `iconKey` with precedence: Delivered → ✅; In delivery → 🚚; else `CreatedDate` is today → ⏳; else ⌛ (status icons override date icons; the page shows a legend stating this and the docs repeat it). Markup: `<apex:slds/>`, `slds-scope`, `slds-table`, `apex:repeat` emitting a summary `<tr>` (expand button with `aria-expanded`, icon via entity, order number, status, effective date, account, total) and a hidden detail `<tr>` with an inner table (product name, quantity, unit price, line total) toggled by 10 lines of vanilla JS. Page meta `availableInTouch=true`; VF tab `abc_Warehouse_Orders` in the app.

### 3.4 Batch archival

`abc_OrderArchiveBatch implements Database.Batchable<SObject>, Database.Stateful` (scope 200). `start`: `SELECT ..., (SELECT ... FROM OrderItems) FROM Order WHERE Status = 'Delivered' AND abc_Order_Date__c < :Date.today().addYears(-1)`. `execute`: map each Order → `abc_Order_Archive__b` (line items → `JSON.serialize` list of `{productName, productCode, quantity, unitPrice, totalPrice}`), call `archiver.archive(rows)` (interface `abc_IOrderArchiver`; default impl `abc_BigObjectOrderArchiver` = `Database.insertImmediate`), for successful rows: `update Status='Draft'` then `delete`; count successes/failures in stateful fields; failures logged via `abc_Logger` (source Batch). `finish`: INFO log summary. `abc_OrderArchiveScheduler implements Schedulable` (cron `0 0 2 * * ?` daily 02:00) scheduled by `scripts/apex/abc_schedule_archive.apex` under the job name `abc_Order_Archive_Nightly`. Tests use `abc_FakeOrderArchiver` (records calls, can simulate failure) — no sObject + big-object mixing in tests (C5). `abc_BigObjectOrderArchiver` gets its own test that only touches the big object: insert one row with order number `TEST-<timestamp>`, query it back by index, `Database.deleteImmediate` it (documented: big-object rows in tests are real).

### 3.5 Logging framework

`abc_Logger`: static buffer of `abc_Log_Event__e`; `debug/info/warn/error(String cls, String method, String message)` + overloads with `Exception` and `Id recordId` and `Integer httpStatus`; captures request id + quiddity + user; `flush()` publishes via `EventBus.publish`. `abc_LogEventTrigger` (after insert) → `abc_LogEventTriggerHandler` (without sharing) → insert `abc_Log__c`. Used by REST resources, batch, and trigger handler. Tab + list view `abc_Recent_Errors` in the app. Tests call `Test.getEventBus().deliver()` before asserting `abc_Log__c` rows.

### 3.6 Security & app

Permission sets (no profile edits): `abc_Pharmacy_Admin` (app, full CRUD on the 7 objects + `abc_Log__c`, all custom fields, tabs, VF page, Activate Orders + Edit Activated Orders + `CreateAuditFields`, all abc classes), `abc_Warehouse_User` (app; object **Read + Edit** on Order and OrderItem so status and product quantities can be updated; read Account/Contact/Product2/PricebookEntry; FLS edit on `Product2.abc_Stock_Quantity__c` and the custom Order fields; Edit Activated Orders; VF page + tabs), `abc_API_Integration` (API Enabled; REST classes; CRUD Order/OrderItem/Account/Contact; read Product2/PricebookEntry/Pricebook2; Activate Orders). Never list universally required standard fields (`Order.Status`, `Order.EffectiveDate`, `OrderItem.Quantity`, `OrderItem.UnitPrice`) in `fieldPermissions` — they are not FLS-controllable and fail deployment. Deploy the permission sets early so invalid entries surface immediately. Lightning app `abc_Pharmacy_Management` with tabs: Accounts, Contacts, Products, Orders, Warehouse Orders (VF), abc Logs.

### 3.7 Extras (in priority order, each droppable)
1. Validation rules (3) — trivial.
2. Record-triggered Flow `abc_Order_Set_Delivered_Date` (before-save on Order: Status = Delivered and `abc_Delivered_Date__c` blank → set today). Author in source; if it fails to deploy twice, build in Flow Builder and retrieve.
3. `abc_OrderTrigger` + `abc_OrderTriggerHandler`: when Status leaves Draft for the first time, decrement `Product2.abc_Stock_Quantity__c` by item quantities (logs a WARN if stock would go negative and clamps to 0).
4. Checkout endpoint (3.2).

## 4. Repository layout (root = `E:\cloudastick`, git root)

```
E:\cloudastick\
  sfdx-project.json, .forceignore, .gitignore, .prettierrc, package.json, README.md
  docs/assessment/Salesforce Entry Assessment.pdf        (moved from root)
  docs/SOLUTION_DOCUMENTATION.md   docs/API_DOCUMENTATION.md   docs/erd.mmd   docs/dist/*.pdf (built)
  postman/abc_Pharmacy_API.postman_collection.json   postman/abc_Pharmacy.postman_environment.json
  scripts/apex/abc_seed_data.apex  abc_schedule_archive.apex  abc_run_archive_now.apex  abc_create_reviewer_user.apex  abc_query_archive.apex
  scripts/build-docs.ps1
  force-app/main/default/
    applications/abc_Pharmacy_Management.app-meta.xml
    classes/  abc_Logger, abc_LogEventTriggerHandler, abc_ApiException, abc_RestResponse, abc_ApiModels,
              abc_ProductService, abc_ProductRestResource, abc_CartService, abc_CartRestResource,
              abc_WarehouseOrdersController, abc_IOrderArchiver, abc_BigObjectOrderArchiver,
              abc_OrderArchiveBatch, abc_OrderArchiveScheduler, abc_OrderTriggerHandler,
              abc_TestDataFactory, abc_FakeOrderArchiver (test), *Test classes (one per class)
    triggers/ abc_LogEventTrigger.trigger, abc_OrderTrigger.trigger
    objects/  Product2/fields+validationRules, Order/fields+validationRules, abc_Order_Archive__b/, abc_Log__c/, abc_Log_Event__e/
    standardValueSets/OrderStatus.standardValueSet-meta.xml
    pages/abc_WarehouseOrders.page (+ .page-meta.xml)
    tabs/abc_Warehouse_Orders.tab-meta.xml, abc_Log__c.tab-meta.xml
    permissionsets/abc_Pharmacy_Admin, abc_Warehouse_User, abc_API_Integration
    flows/abc_Order_Set_Delivered_Date.flow-meta.xml
    layouts/ (only if retrieved to add custom fields to Order/Product2 layouts)
```

## 5. Execution phases (time-boxed for a same-day delivery, ~6.5 h total)

Phase 0 is the user's; everything else is done by Claude in PowerShell with `--target-org abcDev`. Deploy early and often (`sf project deploy start --source-dir force-app/main/default/<part>`), run tests after each Apex phase.

**Phase 0 — User (parallel with Phase 1, ~10 min)**: sign up at https://developer.salesforce.com/signup with a unique username, verify the email, set the password, note the My Domain URL. Have mailbox access ready (ECA secret reveal and login verification codes go there).

**Phase 1 — Tooling, project, repo (~30 min)**
1. `nvm install 24; nvm use 24; npm install -g @salesforce/cli; sf --version`.
2. Generate the project in the scratchpad (`sf project generate --name cloudastick --template standard`), copy its contents into `E:\cloudastick`, move the PDF into `docs/assessment/`.
3. `git init`, commit scaffold; `gh repo create cloudastick-salesforce-assessment --private --source . --remote origin --push`.
4. `sf org login web --alias abcDev --set-default` (browser login).
5. Org checks: `sf org display`; Setup → Order Settings (Enable Orders on); Company Information (license counts, note whether a "Salesforce Integration" license exists); `sf project retrieve start --metadata "Profile:Admin"` into the scratchpad and grep the exact `userPermissions` names for Activate Orders / Edit Activated Orders / API Enabled / Set Audit Fields (then discard the profile file). Confirm `sf api request rest --help` exists for smoke tests (fallback: curl with the token from `sf org display --verbose`).
6. **User-at-keyboard Setup batch (do all now, ~15 min, so nothing later waits on the user or on verification emails)**: (a) Setup → User Interface → enable "Set Audit Fields upon Record Creation"; (b) Setup → Email → Deliverability = "All email"; (c) Setup → External Client App Manager → create `abc_Ionic_App` (Local, OAuth on, callback `https://localhost/callback`, scope `api`, enable Client Credentials Flow, Policies → run-as = admin user), reveal consumer key + secret (verification code email) and save them only in `postman/abc_Pharmacy.local.postman_environment.json` (git-ignored); (d) create the reviewer user now via `sf data create record -s User --values "Username=assessments@cloudastick.com.abcpharmacy Email=assessments@cloudastick.com FirstName=Cloudastick LastName=Assessments Alias=assess ProfileId=<SysAdmin Id> TimeZoneSidKey=Africa/Cairo LocaleSidKey=en_US EmailEncodingKey=UTF-8 LanguageLocaleKey=en_US"` — **do not** send the password reset yet (links expire in 24 h; send in Phase 8).

**Phase 2 — Metadata foundation + shared Apex (~75 min)** — deploy in this order so failures are isolated: (a) Product2/Order custom fields + validation rules + `OrderStatus` standard value set (fallback per C4); (b) `abc_Log_Event__e` + `abc_Log__c` + tab + list view; (c) `abc_Order_Archive__b` (double-check index before deploying — immutable); (d) permission sets, VF placeholder page + tab, Lightning app. Assign all three permission sets to the admin user (`sf org assign permset`). Write `abc_TestDataFactory` + `abc_Logger` + log trigger now (shared by every later phase) and deploy them. Run `scripts/apex/abc_seed_data.apex`: activate standard price book, 10 pharmacy products with PBEs and stock, 3 Account+Contact customers, orders inserted in three steps (Draft with `Pricebook2Id` + `EffectiveDate` → OrderItems → Status update): 1 Draft cart, 1 Activated, 1 In delivery, 2 Delivered (one with `abc_Order_Date__c` = today − 400 days for the batch demo); past orders get an explicit backdated `CreatedDate` (C10). Verify `SELECT Status, StatusCode FROM Order`.

**Phase 3 — REST API (~75 min)**: `abc_ApiException`, `abc_RestResponse`, `abc_ApiModels` → `abc_ProductService` + `abc_ProductRestResource` → `abc_CartService` + `abc_CartRestResource` (+ checkout if time) → tests using `RestContext` and `abc_TestDataFactory`. Smoke test each endpoint with `sf api request rest` (success + 3 error cases) and confirm `abc_Log__c` rows appear for errors. The docs subagent starts here: skeleton of `SOLUTION_DOCUMENTATION.md` from this plan and a working `scripts/build-docs.ps1` (Mermaid via cdnjs; fallback ERD = PNG from mermaid.ink) so Phase 8 only fills in facts.

**Phase 4 — Visualforce (~45 min)**: controller + page + tab wiring + tests (icon precedence: today/past/In delivery/Delivered; expandable items present). `sf org open --path /lightning/n/abc_Warehouse_Orders` and check visually (Chrome MCP screenshot) — icons render, rows expand.

**Phase 5 — Batch archive (~45 min)**: interface + big-object archiver + batch + scheduler + fake archiver + tests (archives only Delivered > 1 year, deletes archived orders, leaves recent ones, handles archiver failure, scheduler schedules). Run `abc_run_archive_now.apex` on the seed data; verify with `abc_query_archive.apex` (SOQL on the big object with index-ordered filter) and that the old order is gone; schedule the nightly job.

**Phase 6 — Extras (~30 min, drop if behind)**: Flow, Order trigger stock decrement + tests, checkout endpoint if not done.

**Phase 7 — Postman (~25 min)**: get a token with curl using the Phase 1 ECA credentials, then author the Postman collection (Auth request with test script storing `access_token`/`_baseUrl`; folders Products / Carts / Error cases, each with status + envelope assertions) and a committed environment with blank secrets. Run the whole collection with `npx newman run` (or in Postman) against the org, then do a fresh import of both JSON files into Postman to prove they load cleanly.

**Phase 8 — Docs, reviewer hand-in (~60 min)**: finish `docs/SOLUTION_DOCUMENTATION.md` (outline in §7), `docs/API_DOCUMENTATION.md`, `README.md`; build PDFs with `scripts/build-docs.ps1` = Markdown → HTML (npx `marked`, embedded CSS, Mermaid from cdnjs) → Chrome headless `--print-to-pdf --virtual-time-budget=10000` → `docs/dist/`. Assign `abc_Pharmacy_Admin` + `abc_Warehouse_User` to the reviewer user, add custom fields to the Order/Product2 page layouts if not yet done, Login-As the reviewer to open the app, Orders tab and Warehouse tab, then run `System.resetPassword(userId, true)` to email the reset link. Final full test run, commit, push, share repo + PDF + Postman + ECA key/secret out-of-band.

**Parallelism (optional, up to 4 subagents after Phase 2)**: Phases 3, 4, 5 touch disjoint files and depend only on `abc_Logger` + `abc_TestDataFactory` (built in Phase 2), so three parallel subagents can write them, each deploying only its own `--source-dir` files and running only its own tests (`sf apex run test --tests ...`); a fourth agent drafts the documentation and the PDF pipeline from this plan while code is built. The main session owns full-suite test runs, seed data, Phases 7–8.

## 6. Verification (must all pass before hand-in)

- `sf project deploy start --source-dir force-app` from a clean checkout succeeds with zero warnings that matter.
- `sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 10`: all tests pass, org coverage ≥ 85%, every `abc_` class ≥ 75%.
- REST via Postman/newman: token issued; products list (filters work); create cart → 201; add item → 200 (merge quantity); unknown cart → 404; qty 0 → 400; malformed JSON → 400; out-of-stock → 409; each error creates an `abc_Log__c` row with the returned `requestId`.
- VF page: opens from the app tab as admin and via Login-As the reviewer; least-privilege access is proven in `abc_WarehouseOrdersControllerTest` with `System.runAs` on a Standard User holding only `abc_Warehouse_User` (test users don't consume licenses); icons follow precedence (create a fresh order today → ⏳; backdated seeded ones → ⌛ unless In delivery/Delivered); rows expand with product name, quantity, unit price.
- Batch: after running on seed data, the >1-year Delivered order is in `abc_Order_Archive__b` (with line items JSON) and deleted from Order; recent Delivered order untouched; `AsyncApexJob` shows Status Completed with `NumberOfErrors` = 0; log summary row exists; scheduled job listed (`SELECT CronJobDetail.Name FROM CronTrigger`).
- Reviewer user is Active, System Administrator, Salesforce license, permission sets assigned, Login-As shows the app with Orders (custom fields on layout) and the Warehouse tab, reset email sent last.
- Naming sweep: every file and `fullName` under `force-app` contains `abc` except standard-object folders, the standard value set and retrieved layouts.
- Docs: PDF opens, ERD renders, Apex component table matches `force-app/classes`, features list matches what was deployed. Collection + environment JSON import cleanly into a fresh Postman workspace.
- Repo pushed; no secrets committed (`.gitignore` covers `.sf/`, `.sfdx/`, `postman/*.local.*`).

## 7. Documentation outline (`docs/SOLUTION_DOCUMENTATION.md` → PDF)

1. Cover + document control (version, date, author) 2. Overview & scope 3. Architecture (component diagram: Ionic → ECA/OAuth → Apex REST → services → objects; VF; batch; logging) 4. Data model: Mermaid ERD, objects table (standard/custom, purpose, key relationships), field catalog, design decisions & assumptions (§3.1 list, incl. C3 license note) 5. Apex components table (class, type, responsibility, test class) + triggers, VF page, flow 6. Salesforce features used and why (Lightning App, Permission Sets, Validation Rules, Record-triggered Flow, Apex REST, Platform Events, Big Objects, Batch/Schedulable Apex, Visualforce + SLDS, External Client App) 7. REST API reference (auth, envelope, endpoints, examples, error codes) — also the standalone `API_DOCUMENTATION.md` for Ionic devs 8. Warehouse page behaviour (icon rules) 9. Archival job (criteria, schedule, how to query the archive, limits) 10. Security model 11. Deployment & setup runbook (CLI commands, ECA steps, seed data) 12. Testing summary (coverage table) 13. Reviewer access & Postman instructions 14. Known limitations / future work.

## 8. Risks & fallbacks

- `OrderStatus` value-set deploy rejected → add "In delivery"/"Delivered" (StatusCode Activated) in Setup, then retrieve the file.
- Big object deployed with wrong index → delete in Setup and **permanently erase** before redeploying under the same name; or use a new name.
- Big-object write inside `execute()` still errors at runtime even with archive-first ordering → move the deactivate+delete into a chained Queueable/second batch keyed by the archived Order Ids.
- `WITH USER_MODE` FLS errors for the run-as user → fix the permission set rather than dropping user mode.
- ECA secret reveal or reviewer-user creation blocked by email verification → user completes the code in the browser; keep both steps for when they're at the keyboard.
- Flow XML fails to deploy → build in Flow Builder, `sf project retrieve start --metadata Flow:abc_Order_Set_Delivered_Date`.
- Time overrun → drop extras in reverse priority (checkout, trigger, flow) but never the reviewer user, Postman, or docs.
