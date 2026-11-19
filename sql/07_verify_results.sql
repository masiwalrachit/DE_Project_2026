-- =====================================================================
-- Team T0147 · Phase 4 · sql/07_verify_results.sql
-- Proof that every rewritten query in sql/06_optimized_queries.sql returns the same
-- result as the original in queries/workload_30.sql (R13 is the intended exception).
--
-- Run (after 05_indexes.sql):
--   psql -d netflix_project -v ON_ERROR_STOP=1 -f sql/07_verify_results.sql
--
-- Method for each rewrite:
--   1. row counts of original and optimized
--   2. (original EXCEPT ALL optimized) and (optimized EXCEPT ALL original) must both be 0
--      EXCEPT ALL also catches duplicate rows, not just distinct ones.
--   3. an md5 checksum of the ordered output where the ORDER BY fully decides the order
-- Queries that were NOT rewritten run unchanged; only indexes changed their plan.
-- =====================================================================
SET search_path TO netflix;

\echo '>> R09: EXTRACT(YEAR) -> sargable range'
WITH o AS (
  SELECT g.genre_name, count(*) AS views,
         round(100.0 * count(*) FILTER (WHERE v.completed) / count(*), 1) AS completion_pct
  FROM viewing_activity v
  JOIN title_genres tg ON tg.title_id = v.title_id
  JOIN genres g        ON g.genre_id = tg.genre_id
  WHERE EXTRACT(YEAR FROM v.started_at) = 2026
  GROUP BY g.genre_name),
n AS (
  SELECT g.genre_name, count(*) AS views,
         round(100.0 * count(*) FILTER (WHERE v.completed) / count(*), 1) AS completion_pct
  FROM viewing_activity v
  JOIN title_genres tg ON tg.title_id = v.title_id
  JOIN genres g        ON g.genre_id = tg.genre_id
  WHERE v.started_at >= '2026-01-01' AND v.started_at < '2027-01-01'
  GROUP BY g.genre_name)
SELECT 'R09' AS query,
       (SELECT count(*) FROM o) AS original_rows,
       (SELECT count(*) FROM n) AS optimized_rows,
       (SELECT count(*) FROM (SELECT * FROM o EXCEPT ALL SELECT * FROM n) x) AS only_in_original,
       (SELECT count(*) FROM (SELECT * FROM n EXCEPT ALL SELECT * FROM o) x) AS only_in_optimized;

\echo '>> R12: EXTRACT(YEAR FROM cancelled_on) -> sargable range'
WITH o AS (
  SELECT date_trunc('month', cancelled_on) AS month, count(*) AS cancellations,
         round(avg(cancelled_on - signup_date), 0) AS avg_tenure_days
  FROM accounts
  WHERE status = 'CANCELLED' AND EXTRACT(YEAR FROM cancelled_on) = 2026
  GROUP BY 1),
n AS (
  SELECT date_trunc('month', cancelled_on) AS month, count(*) AS cancellations,
         round(avg(cancelled_on - signup_date), 0) AS avg_tenure_days
  FROM accounts
  WHERE status = 'CANCELLED'
    AND cancelled_on >= DATE '2026-01-01' AND cancelled_on < DATE '2027-01-01'
  GROUP BY 1)
SELECT 'R12' AS query,
       (SELECT count(*) FROM o) AS original_rows,
       (SELECT count(*) FROM n) AS optimized_rows,
       (SELECT count(*) FROM (SELECT * FROM o EXCEPT ALL SELECT * FROM n) x) AS only_in_original,
       (SELECT count(*) FROM (SELECT * FROM n EXCEPT ALL SELECT * FROM o) x) AS only_in_optimized;

\echo '>> R18: started_at::date >= ... -> started_at >= ...'
WITH o AS (
  SELECT date_trunc('month', started_at) AS month, device_type,
         round(sum(duration_watched_sec) / 3600.0, 0) AS hours
  FROM viewing_activity WHERE started_at::date >= '2026-01-01' GROUP BY 1, 2),
n AS (
  SELECT date_trunc('month', started_at) AS month, device_type,
         round(sum(duration_watched_sec) / 3600.0, 0) AS hours
  FROM viewing_activity WHERE started_at >= '2026-01-01' GROUP BY 1, 2)
SELECT 'R18' AS query,
       (SELECT count(*) FROM o) AS original_rows,
       (SELECT count(*) FROM n) AS optimized_rows,
       (SELECT count(*) FROM (SELECT * FROM o EXCEPT ALL SELECT * FROM n) x) AS only_in_original,
       (SELECT count(*) FROM (SELECT * FROM n EXCEPT ALL SELECT * FROM o) x) AS only_in_optimized;

\echo '>> R19: correlated subqueries -> grouped LEFT JOIN'
WITH o AS (
  SELECT t.title_id, t.name,
         (SELECT count(*) FROM viewing_activity v WHERE v.title_id = t.title_id) AS total_views,
         (SELECT max(v.started_at) FROM viewing_activity v WHERE v.title_id = t.title_id) AS last_viewed_at
  FROM titles t WHERE t.is_netflix_original),
n AS (
  SELECT t.title_id, t.name, COALESCE(v.total_views, 0) AS total_views, v.last_viewed_at
  FROM titles t
  LEFT JOIN (SELECT title_id, count(*) AS total_views, max(started_at) AS last_viewed_at
             FROM viewing_activity GROUP BY title_id) v ON v.title_id = t.title_id
  WHERE t.is_netflix_original)
SELECT 'R19' AS query,
       (SELECT count(*) FROM o) AS original_rows,
       (SELECT count(*) FROM n) AS optimized_rows,
       (SELECT count(*) FROM (SELECT * FROM o EXCEPT ALL SELECT * FROM n) x) AS only_in_original,
       (SELECT count(*) FROM (SELECT * FROM n EXCEPT ALL SELECT * FROM o) x) AS only_in_optimized,
       -- ORDER BY total_views DESC: the sequence of total_views values must be identical.
       -- Rows with equal total_views (ties) may come in any order in BOTH versions,
       -- because the original query does not say how to break ties.
       (SELECT md5(string_agg(total_views::text, ',' ORDER BY total_views DESC)) FROM o)
     = (SELECT md5(string_agg(total_views::text, ',' ORDER BY total_views DESC)) FROM n)
         AS order_column_identical;

\echo '>> R13: NOT IN (wrong, 0 rows) vs NOT EXISTS (correct) - intended difference'
SELECT 'R13' AS query,
       (SELECT count(*) FROM episodes e WHERE e.title_id = 2523
          AND e.episode_id NOT IN (SELECT v.episode_id FROM viewing_activity v)) AS original_not_in_rows,
       (SELECT count(*) FROM episodes e WHERE e.title_id = 2523
          AND NOT EXISTS (SELECT 1 FROM viewing_activity v WHERE v.episode_id = e.episode_id)) AS optimized_not_exists_rows,
       (SELECT count(*) FROM viewing_activity WHERE episode_id IS NULL) AS null_episode_ids_in_subquery,
       -- independent cross-check: episodes of 2523 minus episodes that appear in viewing_activity
       (SELECT count(*) FROM (SELECT episode_id FROM episodes WHERE title_id = 2523
                              EXCEPT
                              SELECT episode_id FROM viewing_activity WHERE episode_id IS NOT NULL) x)
         AS independent_check_rows;
-- Why: "x NOT IN (a, b, NULL)" means x<>a AND x<>b AND x<>NULL. x<>NULL is UNKNOWN,
-- so the whole condition is never TRUE and NOT IN returns no rows at all as soon as the
-- subquery has one NULL. Movie views store episode_id = NULL, so R13 always returned 0.
-- NOT EXISTS checks "is there a matching row?", which is TRUE/FALSE only, so NULLs
-- don't break it. The correct answer is the 8 unwatched episodes.
