-- =====================================================================
-- Netflix Streaming Database: Phase 2 data load
-- Team T0147 (LeadGen) · Author: Akshay
--
-- Run from the project root (the folder that contains seed_data/):
--     psql -d <your_database> -v ON_ERROR_STOP=1 -f sql/02_load_data.sql
--
-- \copy is a psql command: it reads the CSV on YOUR laptop and streams it
-- to the server, so paths are relative to where you run psql.
-- FORMAT csv turns empty unquoted fields into NULL (e.g. phone, leaving_on).
--
-- Load order = parents before children, so every FOREIGN KEY is satisfied:
--   plans, genres  ->  accounts  ->  profiles
--   titles  ->  title_genres, episodes
--   profiles + titles + episodes  ->  viewing_activity, ratings, my_list
--   accounts  ->  invoices
-- For the large dataset (Phase 5) change only the folder name seed_data -> large_data.
-- =====================================================================

SET search_path TO netflix;
SET timezone TO 'Asia/Kolkata';   -- data is in IST; see note in 01_schema.sql

\echo '>> Loading 11 CSV files ...'
\copy plans            FROM 'seed_data/plans.csv'            WITH (FORMAT csv, HEADER true)
\copy genres           FROM 'seed_data/genres.csv'           WITH (FORMAT csv, HEADER true)
\copy accounts         FROM 'seed_data/accounts.csv'         WITH (FORMAT csv, HEADER true)
\copy profiles         FROM 'seed_data/profiles.csv'         WITH (FORMAT csv, HEADER true)
\copy titles           FROM 'seed_data/titles.csv'           WITH (FORMAT csv, HEADER true)
\copy title_genres     FROM 'seed_data/title_genres.csv'     WITH (FORMAT csv, HEADER true)
\copy episodes         FROM 'seed_data/episodes.csv'         WITH (FORMAT csv, HEADER true)
\copy viewing_activity FROM 'seed_data/viewing_activity.csv' WITH (FORMAT csv, HEADER true)
\copy ratings          FROM 'seed_data/ratings.csv'          WITH (FORMAT csv, HEADER true)
\copy my_list          FROM 'seed_data/my_list.csv'          WITH (FORMAT csv, HEADER true)
\copy invoices         FROM 'seed_data/invoices.csv'         WITH (FORMAT csv, HEADER true)

-- Fresh planner statistics after a bulk load (README requires it)
ANALYZE;


-- =====================================================================
-- VERIFY 1: row counts must match the README table
-- =====================================================================
\echo '>> Row counts (actual vs expected)'
SELECT t.table_name, t.actual, t.expected,
       CASE WHEN t.actual = t.expected THEN 'OK' ELSE 'MISMATCH' END AS check_result
FROM (
          SELECT 1 AS ord, 'plans'            AS table_name, (SELECT count(*) FROM plans)            AS actual,      4 AS expected
UNION ALL SELECT 2, 'accounts',         (SELECT count(*) FROM accounts),          25000
UNION ALL SELECT 3, 'profiles',         (SELECT count(*) FROM profiles),          75000
UNION ALL SELECT 4, 'genres',           (SELECT count(*) FROM genres),               15
UNION ALL SELECT 5, 'titles',           (SELECT count(*) FROM titles),             3000
UNION ALL SELECT 6, 'title_genres',     (SELECT count(*) FROM title_genres),       5963
UNION ALL SELECT 7, 'episodes',         (SELECT count(*) FROM episodes),          20000
UNION ALL SELECT 8, 'viewing_activity', (SELECT count(*) FROM viewing_activity), 200401
UNION ALL SELECT 9, 'ratings',          (SELECT count(*) FROM ratings),           33900
UNION ALL SELECT 10,'my_list',          (SELECT count(*) FROM my_list),           59992
UNION ALL SELECT 11,'invoices',         (SELECT count(*) FROM invoices),         133057
) t
ORDER BY t.ord;


-- =====================================================================
-- VERIFY 2: integrity checks the constraints CANNOT express
-- (they compare rows of different tables, or many rows of one table).
-- "violations" = number of rows breaking the rule; 0 means OK.
-- =====================================================================
\echo '>> Integrity checks (violations = 0 means the rule holds)'
SELECT check_no, rule, violations,
       CASE WHEN violations = 0 THEN 'OK' ELSE 'DATA PROBLEM' END AS result
FROM (
-- IC1: each account has at most 5 profiles
SELECT 1 AS check_no, 'Each account has at most 5 profiles' AS rule,
       (SELECT count(*) FROM (SELECT account_id FROM profiles
                              GROUP BY account_id HAVING count(*) > 5) x) AS violations
UNION ALL
-- IC2: nobody watched a title before it was added to the catalogue
SELECT 2, 'Nobody watched a title before it was added',
       (SELECT count(*) FROM viewing_activity v JOIN titles t ON t.title_id = v.title_id
        WHERE v.started_at < t.added_on)
UNION ALL
-- IC3: an episode in viewing_activity belongs to the same series as its title_id
--      (also enforced by fk_viewing_episode_of_title; this proves it on the data)
SELECT 3, 'Viewed episode belongs to the same series as title_id',
       (SELECT count(*) FROM viewing_activity v JOIN episodes e ON e.episode_id = v.episode_id
        WHERE e.title_id <> v.title_id)
UNION ALL
-- IC4: movies are viewed without an episode, series always with one
SELECT 4, 'Movie views have no episode_id, series views always have one',
       (SELECT count(*) FROM viewing_activity v JOIN titles t ON t.title_id = v.title_id
        WHERE (t.title_type = 'MOVIE') <> (v.episode_id IS NULL))
UNION ALL
-- IC5: only SERIES have episodes
SELECT 5, 'Only SERIES titles have episodes',
       (SELECT count(*) FROM episodes e JOIN titles t ON t.title_id = e.title_id
        WHERE t.title_type <> 'SERIES')
UNION ALL
-- IC6: nobody watched for longer than the runtime of what they watched
SELECT 6, 'duration_watched_sec never exceeds the runtime',
       (SELECT count(*) FROM viewing_activity v
        JOIN titles t ON t.title_id = v.title_id
        LEFT JOIN episodes e ON e.episode_id = v.episode_id
        WHERE v.duration_watched_sec > COALESCE(e.runtime_min, t.runtime_min) * 60)
UNION ALL
-- IC7: invoice amount equals the price of the account's plan
SELECT 7, 'Invoice amount = price of the account''s current plan',
       (SELECT count(*) FROM invoices i JOIN accounts a ON a.account_id = i.account_id
        JOIN plans p ON p.plan_id = a.plan_id WHERE i.amount_inr <> p.monthly_price_inr)
UNION ALL
-- IC8: a cancelled account is not invoiced for a month after it cancelled
SELECT 8, 'No invoice after an account was cancelled',
       (SELECT count(*) FROM invoices i JOIN accounts a ON a.account_id = i.account_id
        WHERE a.cancelled_on IS NOT NULL AND i.billing_period_start > a.cancelled_on)
UNION ALL
-- IC9: profiles are not created before their account signed up
SELECT 9, 'Profile not created before the account signed up',
       (SELECT count(*) FROM profiles p JOIN accounts a ON a.account_id = p.account_id
        WHERE p.created_at::date < a.signup_date)
UNION ALL
-- IC10: a profile did not watch anything before it was created
SELECT 10, 'No viewing before the profile was created',
       (SELECT count(*) FROM viewing_activity v JOIN profiles p ON p.profile_id = v.profile_id
        WHERE v.started_at < p.created_at)
UNION ALL
-- IC11: "completed" agrees with how much was watched (>= 90% of the runtime)
SELECT 11, 'completed = TRUE only when >= 90% of the runtime was watched',
       (SELECT count(*) FROM viewing_activity v
        JOIN titles t ON t.title_id = v.title_id
        LEFT JOIN episodes e ON e.episode_id = v.episode_id
        WHERE v.completed
          AND v.duration_watched_sec < 0.9 * COALESCE(e.runtime_min, t.runtime_min) * 60)
UNION ALL
-- IC12: kids profiles never watch content above their maturity limit (compliance, P6)
SELECT 12, 'Kids profiles never watch above their maturity limit',
       (SELECT count(*) FROM viewing_activity v
        JOIN profiles p ON p.profile_id = v.profile_id
        JOIN titles t   ON t.title_id = v.title_id
        WHERE p.is_kids
          AND array_position(ARRAY['U','UA7','UA13','UA16','A'], t.maturity_rating)
            > array_position(ARRAY['U','UA7','UA13','UA16','A'], p.maturity_limit))
) checks
ORDER BY check_no;
