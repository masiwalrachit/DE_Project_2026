# Phase 1: Problem Understanding

## Business context

Netflix India needs one reliable database for subscription plans, customer accounts, profiles, movies and series, episodes, viewing history, ratings, My List entries, and monthly invoices. The database must return user-facing information quickly, produce correct business reports, enforce kids-profile restrictions, and continue performing well as viewing data grows.

## Problems, stakeholders, and workload type

| Problem | Business need in our own words | Main stakeholders | Classification |
|---|---|---|---|
| **P1: Slow home screen** | Continue Watching, Top 10, My List, expiring titles, and recommendation rows must appear without making members wait. | Members, profiles, personalization team, UI team | **Customer-facing / real-time** |
| **P2: Slow title pages, autoplay, and search** | Members must be able to find a title, open its details, and move to the next episode quickly and correctly. | Members, playback team, search team | **Customer-facing / real-time** |
| **P3: Slow sign-in and profile switching** | Email lookup must work even when uppercase and lowercase letters differ, and all profiles of an account should load immediately. | Account owners, profile users, identity team | **Customer-facing / real-time** |
| **P4: Unwatched-episode report is empty** | The content team needs a correct list of episodes with no views so it can study unpopular or undiscovered content. | Content strategy team | **Reporting / analytics** |
| **P5: Slow billing operations** | Failed-payment retries, overdue on-hold accounts, monthly invoice creation, and dunning must finish reliably and fast. | Payments team, billing team, account owners | **Reporting / analytics and batch operations** |
| **P6: Kids safety and account sharing** | Netflix must prove that kids profiles do not view content above their maturity limit and identify accounts exceeding their allowed simultaneous streams. | Children, parents, compliance team, trust and safety team | **Reporting / analytics** |
| **P7: Slow content analytics** | Analysts need completion rates, binge sessions, device usage, ratings, Original-title performance, and My List trends even when viewing data becomes much larger. | Content analytics, content strategy, marketing | **Reporting / analytics** |
| **P8: Finance and support delays** | Finance needs accurate revenue and cancellation reports, while support agents need quick access to recent viewing activity when helping a member. | Finance team, retention team, support team, members | **Mixed:** finance is **reporting / analytics**; support is **customer-facing / real-time** |

## Performance interpretation

Customer-facing queries should normally finish in a few milliseconds because a member is directly waiting. Home-screen and operational queries can take slightly longer but should still feel responsive. Analytical queries may examine many rows and can have a larger time limit, while billing jobs may run as controlled batch operations. Correctness is required in every group; a fast query returning the wrong result is not acceptable.

## Assumptions

1. PostgreSQL 15 or newer is used, and all project tables are created inside the `netflix` schema.
2. An account has one current plan and no more than five profiles.
3. Email comparison for sign-in is case-insensitive, although the stored email value is preserved.
4. Kids profiles may have only `U` or `UA7` maturity limits.
5. A movie has a title-level runtime and no episode; a series has episodes and therefore no title-level runtime.
6. A viewing row without an `episode_id` represents a movie view. A viewing row with an episode must reference the same series as its `title_id`.
7. A cancelled account has a cancellation date and no next billing date. Active or on-hold accounts have a next billing date.
8. A failed invoice has no payment timestamp. Paid or refunded invoices have a payment timestamp.
9. Netflix Originals do not have a leaving date; licensed titles may leave the service.
10. Query optimization must not change the rows or values returned by a query.
