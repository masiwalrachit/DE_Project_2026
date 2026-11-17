# Baseline Timings (CP2, Phase 3: before optimisation)

Evidence: `benchmarks/results/baseline/summary.csv` and the 30 raw plan files `R01.txt` to `W05.txt` (EXPLAIN (ANALYZE, BUFFERS), 3 runs per query, each of the 30 queries from `queries/workload_30.sql`, unmodified). All timings are Execution Time in ms, copied from the `Execution Time:` lines of the raw plans. Average equals `avg_ms` in `summary.csv`. No indexes have been added and no queries changed in this phase.

## 1. Timing table

| Query | Description | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---|---:|---:|---:|---:|
| R01 | "Continue Watching" row: the latest unfinished viewing per title for profile 7043 | READ | 19.782 | 13.619 | 12.741 | 15.381 |
| R02 | Title page: seasons of series 2909 with the number of episodes in each | READ | 0.104 | 0.107 | 0.153 | 0.121 |
| R03 | "Top 10 in India today" row: most-watched titles on 30 June 2026 | READ | 16.606 | 14.395 | 12.128 | 14.376 |
| R04 | Genre row for a kids profile: Comedy titles rated U or UA7, newest additions first | READ | 1.858 | 1.769 | 1.940 | 1.856 |
| R05 | Search: titles whose name contains "love" | READ | 3.331 | 3.006 | 1.719 | 2.685 |
| R06 | "My List" row for profile 7393 | READ | 0.253 | 0.143 | 0.158 | 0.185 |
| R07 | Autoplay: the next episode of series 2909 after season 1 episode 4 | READ | 0.111 | 0.086 | 0.076 | 0.091 |
| R08 | Insights: binge sessions in June 2026 (3+ episodes of one series by one profile on one day) | READ | 25.434 | 19.376 | 16.803 | 20.538 |
| R09 | Content analytics: completion rate per genre (2026) | READ | 53.019 | 50.009 | 49.831 | 50.953 |
| R10 | Sign-in: find the account by email, ignoring case | READ | 5.794 | 5.642 | 5.569 | 5.668 |
| R11 | Payments: active accounts whose June 2026 invoice failed (retry list) | READ | 15.947 | 16.057 | 16.806 | 16.270 |
| R12 | Retention: cancellations per month in 2026 and average tenure (days) of those accounts | READ | 2.678 | 2.681 | 2.732 | 2.697 |
| R13 | Content team: episodes of series 2523 that nobody has watched | READ | 34.775 | 35.997 | 35.524 | 35.432 |
| R14 | Compliance: kids profiles that watched titles above their maturity limit | READ | 44.338 | 44.849 | 45.762 | 44.983 |
| R15 | Finance: active accounts and monthly recurring revenue per plan | READ | 9.151 | 9.306 | 9.261 | 9.239 |
| R16 | Account sharing check: accounts with more profiles watching in the same hour than their plan's streams | READ | 273.769 | 266.087 | 265.471 | 268.442 |
| R17 | Content strategy: share of "LOVE" ratings for Netflix Originals vs licensed titles | READ | 10.129 | 10.068 | 9.938 | 10.045 |
| R18 | Device analytics: viewing hours per device per month in 2026 | READ | 55.445 | 56.522 | 55.637 | 55.868 |
| R19 | Originals report: total views and the most recent view of every Netflix Original | READ | 12684.500 | 12643.250 | 12827.096 | 12718.282 |
| R20 | Marketing: 10 titles added to the most My Lists in June 2026 | READ | 5.517 | 5.391 | 5.635 | 5.514 |
| R21 | Payments: accounts on hold whose billing date has already passed | READ | 2.245 | 2.367 | 2.496 | 2.369 |
| R22 | "Last chance to watch" row: licensed titles leaving in July 2026 | READ | 0.478 | 0.574 | 0.520 | 0.524 |
| R23 | Support console: all viewing activity, newest first, page 6,001 (25 per page) | READ | 86.774 | 77.868 | 75.467 | 80.036 |
| R24 | "Who's watching?" screen: profiles of account 1409 | READ | 0.062 | 0.065 | 0.066 | 0.064 |
| R25 | "More like this": titles sharing at least 2 genres with series 2909 | READ | 1.204 | 1.259 | 1.189 | 1.217 |
| W01 | Player: profile 7043 starts episode S1E5 of series 2909 | WRITE | 0.927 | 1.151 | 1.367 | 1.148 |
| W02 | "+ My List": profile 7043 adds series 2523 | WRITE | 1.731 | 2.476 | 2.363 | 2.190 |
| W03 | Account settings: account 1409 downgrades to the STANDARD plan | WRITE | 1.468 | 1.309 | 1.583 | 1.453 |
| W04 | Monthly billing run: create July 2026 invoices for every active account | WRITE | 142.402 | 159.798 | 163.637 | 155.279 |
| W05 | Dunning: put active accounts whose latest invoice failed on hold | WRITE | 30.153 | 29.423 | 29.017 | 29.531 |

The average of the three runs is the figure used for comparison in Phase 4.

## 2. Plan analysis per query

Each entry lists the scan types, the important joins, sorts and aggregates, why the query is fast or slow, and what part of the plan does most of the work.

**R01**, "Continue Watching" row: the latest unfinished viewing per title for profile 7043 (15.381 ms)  
Parallel Seq Scan on `viewing_activity` (filter `profile_id = 7043 AND NOT completed`, about 200k rows read, almost all removed), then Index Scan on `titles_pkey` for the 1 matching row. A Sort plus Unique implements `DISTINCT ON`. No index starts with `profile_id`, so the whole table is scanned; that scan is nearly all of the work.

**R02**, Title page: seasons of series 2909 with the number of episodes in each (0.121 ms)  
Index Scan on `uq_episodes_series_season_ep` (`title_id = 2909`), about 13 rows, then a GroupAggregate on `season_no`. The composite unique index starts with `title_id`, so it is a pure index lookup. Fast and nothing to fix.

**R03**, "Top 10 in India today" row: most-watched titles on 30 June 2026 (14.376 ms)  
Parallel Seq Scan on `viewing_activity` filtered by the one-day `started_at` range (about 373 of 200k rows kept), Sort, Merge Join to `titles` through `titles_pkey`, GroupAggregate with `count(DISTINCT)`, and a top-N sort for LIMIT 10. No index on `started_at`, so the full-table scan is the main cost; the later steps handle very few rows.

**R04**, Genre row for a kids profile: Comedy titles rated U or UA7, newest additions first (1.856 ms)  
Seq Scan on `titles` (maturity filter), Seq Scan on `title_genres` and `genres`, two Hash Joins and a top-N sort for `ORDER BY added_on DESC LIMIT 40`. All tables are small (3,000 and 5,963 rows), so the query is fast even without indexes. Cost is spread evenly over the scans.

**R05**, Search: titles whose name contains "love" (2.685 ms)  
Seq Scan on `titles` with `name ILIKE '%love%'` (188 of 3,000 rows kept), then top-N sort. A leading-wildcard pattern cannot use a normal B-tree index, so a scan is expected. The table is small, so it stays quick.

**R06**, "My List" row for profile 7393 (0.185 ms)  
Index Scan on `my_list_pkey` (`profile_id = 7393`, 6 rows), Nested Loop with Index Scan on `titles_pkey`, small sort. The primary key starts with `profile_id`, so only a handful of rows is touched. Fast.

**R07**, Autoplay: the next episode of series 2909 after season 1 episode 4 (0.091 ms)  
Index Scan on `uq_episodes_series_season_ep` with the row comparison `(season_no, episode_no) > (1, 4)` and LIMIT 1. The index order matches the `ORDER BY`, so it reads one row and no sort is needed. One of the fastest queries.

**R08**, Insights: binge sessions in June 2026 (3+ episodes of one series by one profile on one day) (20.538 ms)  
Seq Scan on `viewing_activity` (filter `episode_id IS NOT NULL AND started_at >= 2026-06-01`, about 5,818 rows kept), HashAggregate by profile, title and day, `HAVING count(*) >= 3`, then a sort of 1,023 groups. No index on `started_at`, so the scan of all 200k rows dominates.

**R09**, Content analytics: completion rate per genre (2026) (50.953 ms)  
Parallel Seq Scan on `viewing_activity` with `EXTRACT(YEAR FROM started_at) = 2026`, Hash Join to `title_genres` and `genres`, partial and final HashAggregate by genre. About 131k view rows are multiplied by their genres in the join (65,683 rows per worker). The scan and the join of the whole log are the cost. The `EXTRACT` on the column also stops any plain index on `started_at` from being used.

**R10**, Sign-in: find the account by email, ignoring case (5.668 ms)  
Seq Scan on `accounts` with `lower(email) = ...` (24,999 rows removed to find 1). The unique index is on `email` itself, not on `lower(email)`, so it cannot be used. 25k rows are scanned for a single account.

**R11**, Payments: active accounts whose June 2026 invoice failed (retry list) (16.270 ms)  
Seq Scan on `invoices` (status `FAILED` and period 2026-06-01: 1,376 of about 133k rows), Seq Scan on `accounts` (22,021 rows), Hash Join, sort by `account_id`. The scan of `invoices` is the larger part (131,681 rows removed). Moderately quick because both tables fit in memory.

**R12**, Retention: cancellations per month in 2026 and average tenure (days) of those accounts (2.697 ms)  
Seq Scan on `accounts` (`status = 'CANCELLED'` and `EXTRACT(YEAR FROM cancelled_on) = 2026`, 597 rows kept), Sort by month, GroupAggregate. One pass over 25k rows; small output. Fast.

**R13**, Content team: episodes of series 2523 that nobody has watched (35.432 ms)  
Index Scan on `episodes` (`title_id = 2523`, 31 rows) with the filter `NOT (episode_id = ANY (hashed SubPlan))`. The subplan is a Seq Scan on all 200,401 rows of `viewing_activity` to build the hash, which is where the time goes. **Correctness problem:** `viewing_activity.episode_id` is NULL for movie views. `NOT IN` against a list that contains NULL evaluates to unknown for every episode, so the query returns no rows (the plan shows `rows=0`). A `NOT EXISTS` form would return the real unwatched episodes. The query is not rewritten here; the fix belongs to CP3.

**R14**, Compliance: kids profiles that watched titles above their maturity limit (44.983 ms)  
Seq Scan on `viewing_activity` (200,401 rows), Hash Join to kids `profiles` (10,000 rows, `is_kids`), Hash Join to `titles`, a Join Filter comparing `array_position` values (19,679 rows removed, 6,714 kept), and a sort by `started_at DESC`. The full scan of the view log and the two joins make it the third-heaviest read after R16 and R19.

**R15**, Finance: active accounts and monthly recurring revenue per plan (9.239 ms)  
Seq Scan on `accounts` (`status = 'ACTIVE'`, 21,282 rows), Hash Join to the 4-row `plans`, HashAggregate and a 4-row sort. One pass over 25k rows, no index on `status`. Cheap.

**R16**, Account sharing check: accounts with more profiles watching in the same hour than their plan's streams (268.442 ms)  
Seq Scan on `viewing_activity` (200k rows), Hash Joins with `profiles` (75k), `accounts` (25k) and `plans`, then a Sort of all 200,401 joined rows that spills to disk (`external merge`, 6,680 kB) before a GroupAggregate with `count(DISTINCT profile_id)`. Only 22 groups survive `HAVING`. The big sort and disk spill are the main cost; it is the slowest query apart from R19.

**R17**, Content strategy: share of "LOVE" ratings for Netflix Originals vs licensed titles (10.045 ms)  
Seq Scan on `ratings` (33,900 rows), Seq Scan on `titles`, Hash Join and HashAggregate into 2 groups. Every rating is joined to its title; small tables, so about 10 ms.

**R18**, Device analytics: viewing hours per device per month in 2026 (55.868 ms)  
Seq Scan on `viewing_activity` with `started_at::date >= '2026-01-01'` (66,546 rows kept), Sort by month and device (about 4 MB, in memory), GroupAggregate. The cast on the column prevents use of an index on `started_at`; the scan plus the sort of 66k rows is the cost.

**R19**, Originals report: total views and the most recent view of every Netflix Original (12718.282 ms)  
**Intentionally the slowest query.** Seq Scan on `titles` (610 Netflix Originals), and for each of them two correlated subqueries (`count(*)` and `max(started_at)`) each run a full Seq Scan on `viewing_activity` with `title_id = t.title_id` (loops=610 each, about 200k rows read per loop). That is about 1,220 scans of the view log (about 1.95 million buffers), roughly 10.5 ms each. The repeated subplan scans cause essentially all of the 12.7 seconds.

**R20**, Marketing: 10 titles added to the most My Lists in June 2026 (5.514 ms)  
Seq Scan on `my_list` (June 2026 range, 3,328 of 59,992 rows kept), Hash Join with `titles`, HashAggregate (1,917 groups), top-N sort. No index on `added_at`, so the whole table is scanned. Fast.

**R21**, Payments: accounts on hold whose billing date has already passed (2.369 ms)  
Seq Scan on `accounts` (`status = 'ON_HOLD' AND next_billing_date < 2026-07-01`, 739 rows kept) and a small sort. One pass over 25k rows. Fast.

**R22**, "Last chance to watch" row: licensed titles leaving in July 2026 (0.524 ms)  
Seq Scan on `titles` (`leaving_on` in July 2026, 54 of 3,000 rows) and a tiny sort. The table is small, so a scan is cheap. Very fast.

**R23**, Support console: all viewing activity, newest first, page 6,001 (25 per page) (80.036 ms)  
Seq Scan on `viewing_activity` and a full Sort of all rows by `started_at DESC` that spills to disk (`external merge`, 6,680 kB); the first 150,000 rows are then read and thrown away for the OFFSET before 25 rows are returned. Deep OFFSET pagination forces the sort and discard work.

**R24**, "Who's watching?" screen: profiles of account 1409 (0.064 ms)  
Index Scan on `uq_profiles_account_name` (`account_id = 1409`, 4 rows) and a 4-row sort. The unique index starts with `account_id`. Fastest query in the set.

**R25**, "More like this": titles sharing at least 2 genres with series 2909 (1.217 ms)  
Index Only Scan on `title_genres_pkey` (`title_id = 2909`, 3 rows), Hash Join with a Seq Scan on `title_genres` (5,963 rows), HashAggregate with `HAVING count(*) >= 2`, top-N sort. Very small tables, so about 1 ms.

**W01**, Player: profile 7043 starts episode S1E5 of series 2909 (1.148 ms)  
INSERT into `viewing_activity`. The source row comes from an Index Scan on `uq_episodes_series_season_ep`. Time is mostly the three foreign-key trigger checks (profile, title, composite episode-of-title), about 1.1 ms in total. The statement is inside a transaction that is rolled back.

**W02**, "+ My List": profile 7043 adds series 2523 (2.190 ms)  
INSERT ... ON CONFLICT DO NOTHING into `my_list` (Result node, one row). Time is dominated by the two FK trigger checks (profile 1.3 ms, title 0.5 ms). No scan is needed.

**W03**, Account settings: account 1409 downgrades to the STANDARD plan (1.453 ms)  
UPDATE of one `accounts` row: subquery Seq Scan on the 4-row `plans`, Index Scan on `accounts_pkey` (`account_id = 1409`), then the `accounts_plan_id_fkey` check (0.4 ms). Very small write.

**W04**, Monthly billing run: create July 2026 invoices for every active account (155.279 ms)  
INSERT of about 21,282 invoices from a Hash Join of `accounts` (Seq Scan, `status = 'ACTIVE'`) and `plans`. The select part takes only about 8 ms; most of the time is the foreign-key trigger `invoices_account_id_fkey`, called 21,282 times (about 81 ms), plus index and heap maintenance for the inserted rows.

**W05**, Dunning: put active accounts whose latest invoice failed on hold (29.531 ms)  
UPDATE of `accounts` to ON_HOLD: Seq Scan on `invoices` (June 2026 failed invoices, 1,376 rows kept, 131,681 removed) hashed and joined to a Seq Scan on `accounts` (`ACTIVE`, 21,282 rows); 634 accounts are updated. The scan of `invoices` and the write of the changed rows are the cost.

## 3. Key observations

- **R19 (12,718 ms)** is the slowest query by a wide margin, about 47 times slower than the next slowest read (R16, 268 ms). Its two correlated subqueries repeatedly scan `viewing_activity` for every Netflix Original.
- **R13 correctness problem:** `NOT IN` receives NULL `episode_id` values from movie views, so the result becomes unknown and it returns no rows. The query is deliberately left unchanged here; the fix belongs to CP3.
- Most other slow reads are full scans of the 200,401-row `viewing_activity` table where the filter column has no suitable index (R01, R03, R08, R09, R14, R18, R23).
- Fast queries (R02, R06, R07, R24) use indexes that begin with the filtered column.
- Write queries are dominated by foreign-key trigger checks (W01, W02, W04) or a scan of `invoices` (W05).
