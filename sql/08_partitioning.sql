-- =====================================================================
-- Team T0147 · Phase 5 · sql/08_partitioning.sql
-- RANGE partitioning of viewing_activity by month on started_at.
--
-- Run AFTER 01_schema.sql, 02_load_data.sql and 05_indexes.sql
-- (works on the seed database and on the large database):
--   psql -d netflix_project -v ON_ERROR_STOP=1 -f sql/08_partitioning.sql
--
-- What it does (non-destructive):
--   1. creates netflix.viewing_activity_part, partitioned BY RANGE (started_at), one
--      partition per calendar month covering the data, plus a DEFAULT partition;
--   2. copies every row from viewing_activity into it;
--   3. adds the same indexes as 05_indexes.sql (created on the parent, so every
--      partition gets its own copy automatically);
--   4. checks row counts match;
--   5. shows partition pruning with EXPLAIN.
--   The original viewing_activity is NOT dropped, so the benchmark workload keeps
--   working unchanged. Switching the app over is the rename at the bottom (commented).
--
-- WHY this table, this column, RANGE:
--   * viewing_activity is the only table that keeps growing (200k rows seed, ~4M large)
--     and it is append-only: new views always have a newer started_at.
--   * Most heavy queries filter on a started_at range: R03 (one day), R08 (from 1 June),
--     R09 / R18 (2026), R23 (newest first). With monthly RANGE partitions the planner
--     skips every month outside the range (partition pruning) before reading anything.
--   * Old months can be archived with DETACH PARTITION / DROP TABLE in milliseconds,
--     instead of a huge DELETE that bloats the table and needs VACUUM.
--   * LIST does not fit (no small set of values to split by). HASH (e.g. on profile_id)
--     spreads rows evenly but no date query could prune partitions, and archiving old
--     data would still need DELETE.
--   * Monthly, not daily: ~11k rows per month on seed and ~220k on large data; daily
--     would give hundreds of tiny partitions and more planning time for little gain.
--
-- PRIMARY-KEY RULE for partitioned tables:
--   A PRIMARY KEY or UNIQUE constraint on a partitioned table must include all the
--   partition-key columns, because each partition enforces uniqueness only inside
--   itself. So PRIMARY KEY (view_id) is not allowed; it becomes
--   PRIMARY KEY (view_id, started_at). view_id stays unique in practice because it
--   is still unique in the source table and new ids come from one sequence; the
--   database alone no longer guarantees it across months. Nothing references
--   viewing_activity with a foreign key, so no other table has to change.
-- Foreign keys FROM a partitioned table to normal tables (profiles, titles, episodes)
-- are allowed (PostgreSQL 11+) and are kept exactly as in 01_schema.sql.
-- =====================================================================
SET search_path TO netflix;

DROP TABLE IF EXISTS viewing_activity_part CASCADE;

-- 1. Partitioned parent: same columns, types, CHECKs and FKs as viewing_activity.
CREATE TABLE viewing_activity_part (
    view_id               INTEGER      NOT NULL,
    profile_id            INTEGER      NOT NULL
                          REFERENCES profiles (profile_id) ON DELETE CASCADE,
    title_id              INTEGER      NOT NULL
                          REFERENCES titles (title_id) ON DELETE RESTRICT,
    episode_id            INTEGER,
    started_at            TIMESTAMPTZ  NOT NULL,
    duration_watched_sec  INTEGER      NOT NULL,
    device_type           VARCHAR(6)   NOT NULL,
    completed             BOOLEAN      NOT NULL,
    CONSTRAINT pk_viewing_part PRIMARY KEY (view_id, started_at),   -- must contain started_at
    CONSTRAINT fk_viewing_part_episode_of_title
        FOREIGN KEY (episode_id, title_id)
        REFERENCES episodes (episode_id, title_id) ON DELETE RESTRICT,
    CONSTRAINT chk_viewing_part_duration CHECK (duration_watched_sec > 0),
    CONSTRAINT chk_viewing_part_device   CHECK (device_type IN ('TV', 'MOBILE', 'LAPTOP', 'TABLET'))
) PARTITION BY RANGE (started_at);

-- 2. One partition per month, from the first to the last month present in the data,
--    so the same file works for seed_data and large_data. Bounds are midnight on the
--    1st in the database time zone (Asia/Kolkata), FROM inclusive, TO exclusive.
--    Names: viewing_activity_y2026m06 etc.
DO $$
DECLARE
    m     date;
    first date;
    last  date;
BEGIN
    SELECT date_trunc('month', min(started_at))::date,
           date_trunc('month', max(started_at))::date
      INTO first, last
      FROM viewing_activity;

    FOR m IN SELECT generate_series(first, last, interval '1 month')::date LOOP
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF viewing_activity_part
                 FOR VALUES FROM (%L) TO (%L)',
            'viewing_activity_' || to_char(m, '"y"YYYY"m"MM'),
            m::timestamptz, (m + interval '1 month')::timestamptz);
    END LOOP;
END $$;

-- Safety net: a row outside every month range (e.g. a future month not yet created)
-- goes here instead of failing the INSERT. A monthly job should create next month's
-- partition ahead of time so this stays empty.
CREATE TABLE viewing_activity_default PARTITION OF viewing_activity_part DEFAULT;

-- 3. Copy the data (each row is routed to its month automatically).
INSERT INTO viewing_activity_part
SELECT view_id, profile_id, title_id, episode_id, started_at,
       duration_watched_sec, device_type, completed
FROM viewing_activity;

-- 4. Same indexes as sql/05_indexes.sql. Created on the parent = one index per partition.
CREATE INDEX idx_vap_profile_title_started
    ON viewing_activity_part (profile_id, title_id, started_at DESC);      -- R01
CREATE INDEX idx_vap_started_cover
    ON viewing_activity_part (started_at)
    INCLUDE (view_id, profile_id, title_id, episode_id);                   -- R03 R08 R23
CREATE INDEX idx_vap_episode_notnull
    ON viewing_activity_part (episode_id) WHERE episode_id IS NOT NULL;    -- R13

VACUUM ANALYZE viewing_activity_part;

-- 5. Checks: same number of rows, nothing landed in DEFAULT, rows per partition.
SELECT (SELECT count(*) FROM viewing_activity)          AS original_rows,
       (SELECT count(*) FROM viewing_activity_part)     AS partitioned_rows,
       (SELECT count(*) FROM viewing_activity_default)  AS rows_in_default;

SELECT c.relname AS partition, pg_get_expr(c.relpartbound, c.oid) AS bounds,
       s.n_live_tup AS rows
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE i.inhparent = 'netflix.viewing_activity_part'::regclass
ORDER BY c.relname;

-- Same result check: the two tables hold exactly the same rows.
SELECT (SELECT count(*) FROM (SELECT * FROM viewing_activity
                              EXCEPT ALL SELECT * FROM viewing_activity_part) x) AS only_in_original,
       (SELECT count(*) FROM (SELECT * FROM viewing_activity_part
                              EXCEPT ALL SELECT * FROM viewing_activity) x)      AS only_in_partitioned;

-- 6. Partition pruning demos. Look for how many partitions appear in each plan.
-- R03 shape: one day -> only ONE monthly partition is scanned.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*), sum(duration_watched_sec)
FROM viewing_activity_part
WHERE started_at >= '2026-06-15' AND started_at < '2026-06-16';

-- R08 shape: from 1 June onwards -> only June 2026 and later partitions.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*)
FROM viewing_activity_part
WHERE episode_id IS NOT NULL AND started_at >= '2026-06-01';

-- R09 shape (rewritten, sargable): all of 2026 -> 2025 partitions are skipped.
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*)
FROM viewing_activity_part
WHERE started_at >= '2026-01-01' AND started_at < '2027-01-01';

-- Counter-example: the ORIGINAL R09 filter EXTRACT(YEAR FROM started_at) = 2026 hides
-- the column inside a function, so the planner cannot prune: EVERY partition is scanned.
-- (Partitioning only helps queries that filter on started_at directly.)
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*)
FROM viewing_activity_part
WHERE EXTRACT(YEAR FROM started_at) = 2026;

-- Archiving example (NOT executed): removing a whole old month is instant, no DELETE,
-- no table bloat, no VACUUM:
--   ALTER TABLE viewing_activity_part DETACH PARTITION viewing_activity_y2025m01;
--   DROP TABLE viewing_activity_y2025m01;        -- or move it to cheap storage first

-- Creating next month ahead of time (monthly job, NOT executed here):
--   CREATE TABLE viewing_activity_y2026m08 PARTITION OF viewing_activity_part
--       FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');

-- Switching the application to the partitioned table (NOT executed, so the 30-query
-- benchmark keeps running against the original table):
--   BEGIN;
--   ALTER TABLE viewing_activity      RENAME TO viewing_activity_old;
--   ALTER TABLE viewing_activity_part RENAME TO viewing_activity;
--   COMMIT;
