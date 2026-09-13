# ABC Pharmacy — Salesforce Entry Assessment

Salesforce Developer Edition implementation for pharmacy **ABC**, built for the Cloudastick Systems
entry assessment: a data model and Lightning app for customers, products and orders; Apex REST
endpoints for the Ionic mobile app; a Visualforce warehouse console; and a Batch Apex archival job
that moves year-old delivered orders into a Big Object.

Every custom API name in this project is prefixed `abc_`, as required by the assessment.

| Document | Purpose |
|---|---|
| [`docs/SOLUTION_DOCUMENTATION.md`](docs/SOLUTION_DOCUMENTATION.md) | Full solution documentation — architecture, ERD, Apex components, features and rationale |
| [`docs/API_DOCUMENTATION.md`](docs/API_DOCUMENTATION.md) | REST API reference for the Ionic app developers |
| [`postman/`](postman) | Postman collection + environment covering every endpoint |
| [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) | Design spec and build plan |

## Quick start

```bash
sf org login web --alias abcDev --set-default
sf project deploy start --source-dir force-app
sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 10
```

_Status: build in progress._
