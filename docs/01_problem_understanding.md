# Phase 1: Problem Understanding

## Business context

Netflix India needs a correct, fast database for accounts, profiles, catalogue content, viewing, personalization, and billing that can continue working as data grows.

## Problems, stakeholders, and workload type

| Problem | Business need in our own words | Main stakeholders | Classification |
|---|---|---|---|
| **P1: Home screen** | Load Continue Watching, Top 10, My List, expiring titles, and recommendations quickly. | Members, personalization/UI | **Customer-facing / real-time** |
| **P2: Playback and search** | Find titles, open title pages, and select the next episode without delay. | Members, playback, search | **Customer-facing / real-time** |
| **P3: Identity** | Find email regardless of letter case and load account profiles quickly. | Account/profile users, identity | **Customer-facing / real-time** |
| **P4: Unwatched episodes** | Correctly report episodes with no views instead of returning an empty report. | Content strategy | **Reporting / analytics** |
| **P5: Billing** | Process retries, overdue accounts, invoices, and dunning reliably. | Payments and billing | **Reporting / analytics (batch)** |
| **P6: Compliance** | Detect kids viewing above limits and accounts exceeding allowed streams. | Children, parents, compliance/trust | **Reporting / analytics** |
| **P7: Content insights** | Calculate binge, completion, device, rating, Original, and My List statistics at larger scale. | Analytics, content, marketing | **Reporting / analytics** |
| **P8: Finance and support** | Report revenue/churn and quickly retrieve member viewing history for support. | Finance, retention, support, members | **Mixed:** finance is analytics; support is real-time |

## Assumptions

1. PostgreSQL 15+ is used and every table is inside the `netflix` schema.
2. An account has one current plan and at most five profiles; sign-in email comparison is case-insensitive.
3. Kids profiles use only `U` or `UA7` limits.
4. Movies have title runtimes and no episode; series store runtimes in their episodes.
5. Cancelled accounts have a cancellation date and no next bill; failed invoices have no payment time.
6. Netflix Originals do not leave the service, and optimization must never change query results.
