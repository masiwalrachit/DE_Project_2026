-- =====================================================================
-- Team T0147 · Phase 4 · sql/05_indexes.sql
-- Performance indexes for queries/workload_30.sql and sql/06_optimized_queries.sql.
--
-- Run AFTER 01_schema.sql and 02_load_data.sql:
--   psql -d netflix_project -v ON_ERROR_STOP=1 -f sql/05_indexes.sql
--
-- Rules followed:
--   * 01_schema.sql is not changed; only CREATE INDEX (+ pg_trgm for R05).
--   * No index duplicates an existing PK/UNIQUE index. Existing ones are:
--       viewing_activity_pkey (view_id), titles_pkey, my_list_pkey (profile_id, title_id),
--       accounts_pkey, accounts_email_key (email), accounts_phone_key,
--       invoices_pkey, uq_invoices_account_period (account_id, billing_period_start),
--       uq_episodes_series_season_ep (title_id, season_no, episode_no),
--       uq_episodes_id_title (episode_id, title_id), uq_profiles_account_name,
--       ratings_pkey (profile_id, title_id), title_genres_pkey, plans/genres PKs.
--     R02, R06, R07, R24 already use those indexes (baseline < 0.2 ms), so nothing new for them.
--   * B-tree column order: equality columns first, then the range / ORDER BY column.
--   * Every index says which queries it serves and why this type and column order.
--   * The file is re-runnable (IF NOT EXISTS).
-- =====================================================================
SET search_path TO netflix;

-- ---------------------------------------------------------------------
-- 1. viewing_activity (profile_id, title_id, started_at DESC)
-- Serves: R01 (Continue Watching) and the ON DELETE CASCADE from profiles (finding a
--         profile's views by profile_id).
-- Why:    R01 filters profile_id = 7043 (equality first) and then wants rows per title_id
--         ordered by started_at DESC for DISTINCT ON (v.title_id). With this column order
--         one profile's rows sit together in (title_id, started_at DESC) order, so the
--         Seq Scan on 200k rows becomes a few index lookups.
--         Kept non-partial (not WHERE NOT completed) so deleting a profile (CASCADE) can
--         also find its views by profile_id. R14 was tested: the planner still prefers a
--         Seq Scan + Hash Join there (all views of 10,000 kids profiles = 13% of profiles), which is
--         correct, so R14 is listed under "not sped up" in the report.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_va_profile_title_started
    ON viewing_activity (profile_id, title_id, started_at DESC);

-- ---------------------------------------------------------------------
-- 2. viewing_activity (started_at) INCLUDE (view_id, profile_id, title_id, episode_id)
-- Serves: R03 (one day), R08 (June onwards), R23 (newest-first page), R18 / R09 range scans.
-- Why:    every one of these filters or sorts on started_at only, so it is the single key
--         column (B-tree supports both >= / < ranges and ORDER BY ... DESC by scanning
--         backwards). The INCLUDE columns are exactly the other columns R23 selects
--         (view_id, profile_id, title_id, episode_id) and the ones R03/R08 need, so these
--         queries become Index Only Scans and never touch the heap (needs the VACUUM below
--         to set the visibility map). R23 still walks 150,025 index entries for OFFSET,
--         but it no longer sorts 200k rows on disk (baseline: external merge).
--         BRIN was considered (data is loaded in time order) but BRIN cannot return rows
--         in order, so it cannot remove R23's sort; B-tree chosen.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_va_started_cover
    ON viewing_activity (started_at)
    INCLUDE (view_id, profile_id, title_id, episode_id);

-- ---------------------------------------------------------------------
-- 3. Partial index viewing_activity (episode_id) WHERE episode_id IS NOT NULL
-- Serves: R13 (rewritten with NOT EXISTS: "has anyone watched this episode?").
-- Why:    the anti-join probes viewing_activity by episode_id for each of the episodes
--         of series 2523. Movie views have episode_id NULL and can never match
--         (v.episode_id = e.episode_id), so they are left out of the index: smaller index,
--         same answers. The planner can use it because "=" implies IS NOT NULL.
--         (uq_episodes_id_title is on episodes, not viewing_activity, so no duplicate.)
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_va_episode_notnull
    ON viewing_activity (episode_id)
    WHERE episode_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 4. Expression index accounts (lower(email))
-- Serves: R10 (sign-in, case-insensitive email).
-- Why:    the query filters on lower(email), not email, so accounts_email_key cannot be
--         used (baseline: Seq Scan on accounts). An expression index on exactly
--         lower(email) turns it into an Index Scan returning 1 row.
--         Not UNIQUE on purpose: the schema keeps email case-sensitive-unique only, and the
--         data was not checked for case-variant duplicates; a plain index cannot fail.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_accounts_lower_email
    ON accounts (lower(email));

-- ---------------------------------------------------------------------
-- 5. Partial index invoices (billing_period_start, account_id) WHERE status = 'FAILED'
-- Serves: R11 (failed June invoices, ORDER BY account_id), W05 (dunning EXISTS).
-- Why:    FAILED is a small share of 133k invoices, so a partial index holds only the rows
--         these two queries can ever want. Equality column billing_period_start first, then
--         account_id, so R11 reads June's failed invoices already sorted by account_id, and
--         W05 finds the failed June invoices without scanning invoices.
--         Bonus for writes: W04 inserts PAID invoices, which are not in this index,
--         so this index adds no cost to the monthly billing run.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_invoices_failed_period_account
    ON invoices (billing_period_start, account_id)
    WHERE status = 'FAILED';

-- ---------------------------------------------------------------------
-- 6. Partial index accounts (next_billing_date) WHERE status = 'ON_HOLD'
-- Serves: R21 (on-hold accounts whose billing date has passed, ORDER BY next_billing_date).
-- Why:    only 739 of 25,000 accounts are ON_HOLD. The partial index stores just those,
--         keyed on the range + sort column, so R21 is a range scan that is already sorted.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_accounts_onhold_next_billing
    ON accounts (next_billing_date)
    WHERE status = 'ON_HOLD';

-- ---------------------------------------------------------------------
-- 7. Partial index accounts (cancelled_on) WHERE status = 'CANCELLED'
-- Serves: R12 (rewritten: cancellations in 2026 as a sargable date range).
-- Why:    cancelled_on is only set for CANCELLED accounts (CHECK in 01_schema.sql), so the
--         partial index is small (2,979 rows) and the range on cancelled_on can use it.
--         Only works because the rewrite removed EXTRACT(YEAR FROM cancelled_on).
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_accounts_cancelled_on
    ON accounts (cancelled_on)
    WHERE status = 'CANCELLED';

-- ---------------------------------------------------------------------
-- 8. my_list (added_at) INCLUDE (title_id)
-- Serves: R20 (titles added to My List in June 2026).
-- Why:    the query filters a one-month range on added_at; my_list_pkey starts with
--         profile_id and cannot help. title_id is INCLUDEd so the range is read as an
--         Index Only Scan and grouped without touching the heap.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_my_list_added_at
    ON my_list (added_at) INCLUDE (title_id);

-- ---------------------------------------------------------------------
-- 9. Partial index titles (leaving_on) WHERE leaving_on IS NOT NULL
-- Serves: R22 ("last chance to watch": leaving in July 2026, ORDER BY leaving_on).
-- Why:    most titles (all Originals) have leaving_on NULL; a BETWEEN can never match NULL,
--         so only titles with a leaving date are indexed. Range + sort on the same column.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_titles_leaving_on
    ON titles (leaving_on)
    WHERE leaving_on IS NOT NULL;

-- ---------------------------------------------------------------------
-- 10. GIN trigram index titles (name gin_trgm_ops)
-- Serves: R05 (search: name ILIKE '%love%').
-- Why:    a leading-wildcard ILIKE cannot use a B-tree at all. pg_trgm splits names into
--         3-letter pieces; the GIN index finds names containing 'lov' and 'ove' and then
--         rechecks the ILIKE. Requires the pg_trgm extension (ships with PostgreSQL /
--         Postgres.app, no separate download).
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_titles_name_trgm
    ON titles USING gin (name gin_trgm_ops);

-- ---------------------------------------------------------------------
-- Not indexed, on purpose (explained in docs/04_optimization_report.md):
--   R04, R15, R17, R25 : small tables or aggregates over the whole table; already a few ms.
--   R16                : must read every viewing row (account sharing per hour over all
--                        history); an index cannot avoid reading the whole table.
--   R19                : fixed by the rewrite (one grouped pass); an index on
--                        viewing_activity(title_id, started_at) was tested and the planner
--                        did not use it for the rewritten query, so it was not kept.
--   R09, R18           : read about a third of viewing_activity (all of 2026); a Seq Scan
--                        is the right plan, the gain comes from the sargable rewrite.
--   W01–W05            : writes; each new index above is extra work on INSERT/UPDATE,
--                        measured as write overhead in the report.
-- ---------------------------------------------------------------------

-- Fresh statistics for the planner, and a fresh visibility map so the
-- INCLUDE / covering indexes above can give Index Only Scans.
-- (VACUUM cannot run inside a transaction block, so this file has no BEGIN/COMMIT.)
VACUUM ANALYZE viewing_activity;
VACUUM ANALYZE accounts;
VACUUM ANALYZE invoices;
VACUUM ANALYZE my_list;
VACUUM ANALYZE titles;
