# ABC Pharmacy — Salesforce Entry Assessment

A Salesforce Developer Edition implementation for pharmacy **ABC**, built for the
Cloudastick Systems entry assessment.

Pharmacy ABC needs to manage customers, a product catalogue and orders; its Ionic
mobile app needs an API to browse products and build a cart; its single warehouse
operator needs one screen to work from; and delivered orders older than a year
need to move out of the way into cold storage.

Every custom API name in this project is prefixed **`abc_`**, as the assessment
requires.

## What is here

| | |
|---|---|
| **Data model** | Standard `Account` / `Contact` / `Product2` / `Order` / `OrderItem`, extended with `abc_` fields, plus a Lightning app |
| **REST API** | `GET /abc/v1/products`, and carts with create / read / add item / checkout |
| **Warehouse console** | A Visualforce page listing every order with status icons and expandable line items |
| **Archival** | Batch Apex moving year-old delivered orders into the `abc_Order_Archive__b` big object, nightly at 02:00 |
| **Logging** | Platform-event backed, so a log survives the transaction that rolled back |

**133 tests, 100% passing, 91% org-wide coverage.**

## Documentation

| Document | For |
|---|---|
| [`docs/SOLUTION_DOCUMENTATION.md`](docs/SOLUTION_DOCUMENTATION.md) | The full write-up: architecture, ERD, every Apex component, the features used and why, security model, runbook, testing, limitations |
| [`docs/API_DOCUMENTATION.md`](docs/API_DOCUMENTATION.md) | Standalone REST reference for the Ionic app developers |
| [`postman/`](postman) | Postman collection and environment covering every endpoint |
| [`docs/dist/`](docs/dist) | PDF builds of both documents |

## Repository layout

```
force-app/main/default/
  applications/     abc_Pharmacy_Management — the Lightning app
  classes/          15 classes + 11 test classes and 2 test helpers
  objects/          abc_ fields on Product2 and Order, plus abc_Log__c,
                    abc_Log_Event__e and the abc_Order_Archive__b big object
  pages/            abc_WarehouseOrders — the warehouse console
  permissionsets/   abc_Pharmacy_Admin, abc_Warehouse_User, abc_API_Integration
  standardValueSets/OrderStatus — adds "In delivery" and "Delivered"
  tabs/             abc_Warehouse_Orders, abc_Log__c
  triggers/         abc_LogEventTrigger
docs/               solution and API documentation, the ERD, built PDFs
postman/            collection + environment
scripts/apex/       seed and archival runbook scripts
scripts/build-docs.ps1   Markdown -> HTML -> PDF, no global installs
```

## Prerequisites

- Salesforce CLI (`@salesforce/cli`) on **Node 24 LTS** — the CLI does not
  support odd-numbered Node releases
- A Salesforce Developer Edition org with Orders enabled

## Getting started

```bash
sf org login web --alias abcDev --set-default
sf project deploy start --source-dir force-app

sf org assign permset --name abc_Pharmacy_Admin
sf org assign permset --name abc_Warehouse_User
sf org assign permset --name abc_API_Integration

sf apex run --file scripts/apex/abc_seed_data.apex
```

Then open the **ABC Pharmacy Management** app and its **Warehouse Orders** tab.

Two org settings are not exposed to the Metadata API and must be enabled in
Setup by hand — see
[the runbook](docs/SOLUTION_DOCUMENTATION.md#111-deploy-into-a-fresh-org) for
both, and for registering the External Client App the REST API authenticates
against.

## Tests

```bash
sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 20
```

## Archival job

```bash
sf apex run --file scripts/apex/abc_schedule_archive.apex        # nightly at 02:00
sf apex run --file scripts/apex/abc_run_archive_now.apex         # run it now
sf apex run --file scripts/apex/abc_query_archive.apex           # read the archive back
sf apex run --file scripts/apex/abc_seed_archivable_order.apex   # re-arm the demo
```

## Building the PDFs

```bash
npm run docs        # or: pwsh -File scripts/build-docs.ps1
```

Markdown → HTML (with Mermaid diagrams) → PDF via headless Chrome. No pandoc, no
global installs.
