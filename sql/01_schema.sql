-- =====================================================================
-- Netflix Movie & Series Streaming Database: Phase 2 schema
-- Team T0147 (LeadGen) · Author: Akshay
--
-- Run on an EMPTY database (PostgreSQL 15+):
--     psql -d <your_database> -v ON_ERROR_STOP=1 -f sql/01_schema.sql
--
-- Rules followed (README, section 2.2):
--   * Every table lives in schema "netflix".
--   * Table and column names are exactly the CSV file names / headers.
--   * ONLY constraints here: PRIMARY KEY, FOREIGN KEY, UNIQUE, NOT NULL, CHECK.
--     No other index is created. PostgreSQL builds an index automatically
--     for every PRIMARY KEY and UNIQUE constraint; those are listed at the
--     bottom of this file.
--
-- ON DELETE policy used everywhere:
--   * CASCADE  : the child row only makes sense inside its parent
--                (a profile inside an account, a rating inside a profile).
--   * RESTRICT : the child is a business / financial / history record
--                that must never disappear silently (invoices, viewing
--                history, accounts on a plan, episodes of a watched title).
--   * SET NULL : not used. No nullable FK should lose its parent silently
--                (viewing_activity.episode_id is NULL only for movies).
-- =====================================================================

DROP SCHEMA IF EXISTS netflix CASCADE;   -- makes the script safe to re-run
CREATE SCHEMA netflix;
SET search_path TO netflix;

-- All timestamps in the data carry +05:30 (Netflix India). Make IST the default
-- time zone of this database, so date boundaries like '2026-06-30' (R03),
-- started_at::date (R08, R18) and timestamp-vs-date comparisons mean the same
-- calendar day on every laptop, whatever the server's own time zone is.
-- (A display/semantics setting, not a performance setting.)
DO $$ BEGIN
    EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'Asia/Kolkata');
END $$;
SET timezone TO 'Asia/Kolkata';


-- ---------------------------------------------------------------------
-- 1. plans: the 4 subscription plans (lookup table)
-- ---------------------------------------------------------------------
CREATE TABLE plans (
    plan_id            SMALLINT      PRIMARY KEY,               -- only 4 rows, 2 bytes is enough
    plan_name          VARCHAR(10)   NOT NULL UNIQUE,           -- natural key; W03 looks it up by name
    monthly_price_inr  NUMERIC(8,2)  NOT NULL,                  -- money: exact decimal, never FLOAT
    max_streams        SMALLINT      NOT NULL,
    max_resolution     VARCHAR(5)    NOT NULL,
    has_ads            BOOLEAN       NOT NULL DEFAULT FALSE,

    CONSTRAINT chk_plans_name       CHECK (plan_name IN ('MOBILE', 'BASIC', 'STANDARD', 'PREMIUM')),
    CONSTRAINT chk_plans_price      CHECK (monthly_price_inr > 0),
    CONSTRAINT chk_plans_streams    CHECK (max_streams BETWEEN 1 AND 4),
    CONSTRAINT chk_plans_resolution CHECK (max_resolution IN ('480p', '720p', '1080p', '4K'))
);


-- ---------------------------------------------------------------------
-- 2. genres: 15 genres (lookup table)
-- ---------------------------------------------------------------------
CREATE TABLE genres (
    genre_id    SMALLINT     PRIMARY KEY,
    genre_name  VARCHAR(30)  NOT NULL UNIQUE                    -- R04 / R09 filter and group by name
);


-- ---------------------------------------------------------------------
-- 3. accounts: one paying household
-- ---------------------------------------------------------------------
CREATE TABLE accounts (
    account_id         INTEGER       PRIMARY KEY,
    email              VARCHAR(254)  NOT NULL UNIQUE,            -- sign-in identifier (254 = max email length).
                                                                 -- Stored as typed (case preserved, see docs/01 assumption 3);
                                                                 -- the case-insensitive lookup in R10 is a Phase 4 topic.
    phone              VARCHAR(15)   UNIQUE,                     -- optional (4,888 accounts have none); text, not a number
    country_code       CHAR(2)       NOT NULL,                   -- ISO-3166 code: IN / AE / SG
    plan_id            SMALLINT      NOT NULL
                       REFERENCES plans (plan_id) ON DELETE RESTRICT,  -- a plan in use cannot be deleted
    signup_date        DATE          NOT NULL,
    status             VARCHAR(10)   NOT NULL,
    cancelled_on       DATE,                                     -- only for CANCELLED accounts
    next_billing_date  DATE,                                     -- NULL once the account is cancelled

    CONSTRAINT chk_accounts_status        CHECK (status IN ('ACTIVE', 'ON_HOLD', 'CANCELLED')),
    -- a cancelled account has a cancellation date, and only a cancelled one has it
    CONSTRAINT chk_accounts_cancel_date   CHECK ((status = 'CANCELLED') = (cancelled_on IS NOT NULL)),
    -- a cancelled account is never billed again; every other account has a next billing date
    CONSTRAINT chk_accounts_next_billing  CHECK ((status = 'CANCELLED') = (next_billing_date IS NULL)),
    CONSTRAINT chk_accounts_cancel_after  CHECK (cancelled_on >= signup_date),
    CONSTRAINT chk_accounts_email_format  CHECK (email LIKE '_%@_%._%'),
    CONSTRAINT chk_accounts_phone_digits  CHECK (phone ~ '^[0-9]{10}$'),
    CONSTRAINT chk_accounts_country       CHECK (country_code ~ '^[A-Z]{2}$')
);


-- ---------------------------------------------------------------------
-- 4. profiles: up to 5 per account; kids profiles limited to U / UA7
-- ---------------------------------------------------------------------
CREATE TABLE profiles (
    profile_id      INTEGER      PRIMARY KEY,
    account_id      INTEGER      NOT NULL
                    REFERENCES accounts (account_id) ON DELETE CASCADE,  -- a profile cannot exist without its account
    profile_name    VARCHAR(30)  NOT NULL,
    is_kids         BOOLEAN      NOT NULL DEFAULT FALSE,
    maturity_limit  VARCHAR(4)   NOT NULL,
    language        VARCHAR(20)  NOT NULL,
    created_at      TIMESTAMPTZ  NOT NULL,                       -- data carries a +05:30 offset

    -- two profiles in the same household can't have the same name ("Who's watching?" screen)
    CONSTRAINT uq_profiles_account_name  UNIQUE (account_id, profile_name),
    CONSTRAINT chk_profiles_maturity     CHECK (maturity_limit IN ('U', 'UA7', 'UA13', 'UA16', 'A')),
    -- kids profiles are limited to U / UA7 content
    CONSTRAINT chk_profiles_kids_limit   CHECK (NOT is_kids OR maturity_limit IN ('U', 'UA7'))
);


-- ---------------------------------------------------------------------
-- 5. titles: movies and series in the catalogue
-- ---------------------------------------------------------------------
CREATE TABLE titles (
    title_id             INTEGER       PRIMARY KEY,
    title_type           VARCHAR(6)    NOT NULL,
    name                 VARCHAR(200)  NOT NULL,                 -- not UNIQUE: two films may share a name
    release_year         SMALLINT      NOT NULL,
    maturity_rating      VARCHAR(4)    NOT NULL,
    original_language    VARCHAR(20)   NOT NULL,
    runtime_min          SMALLINT,                               -- movies only; a series' runtime lives in episodes
    is_netflix_original  BOOLEAN       NOT NULL DEFAULT FALSE,
    added_on             DATE          NOT NULL,
    leaving_on           DATE,                                   -- only licensed titles with an end date

    CONSTRAINT chk_titles_type           CHECK (title_type IN ('MOVIE', 'SERIES')),
    CONSTRAINT chk_titles_maturity       CHECK (maturity_rating IN ('U', 'UA7', 'UA13', 'UA16', 'A')),
    CONSTRAINT chk_titles_release_year   CHECK (release_year BETWEEN 1900 AND 2100),
    CONSTRAINT chk_titles_runtime        CHECK (runtime_min BETWEEN 1 AND 600),
    -- movies have a runtime, series don't
    CONSTRAINT chk_titles_movie_runtime  CHECK ((title_type = 'MOVIE') = (runtime_min IS NOT NULL)),
    -- Netflix Originals are owned by Netflix, so they never leave the service
    CONSTRAINT chk_titles_original_stays CHECK (NOT (is_netflix_original AND leaving_on IS NOT NULL)),
    CONSTRAINT chk_titles_leave_after    CHECK (leaving_on > added_on)
);


-- ---------------------------------------------------------------------
-- 6. title_genres: M:N between titles and genres
-- ---------------------------------------------------------------------
CREATE TABLE title_genres (
    title_id  INTEGER   NOT NULL
              REFERENCES titles (title_id) ON DELETE CASCADE,    -- tags die with the title
    genre_id  SMALLINT  NOT NULL
              REFERENCES genres (genre_id) ON DELETE RESTRICT,   -- can't drop a genre still in use
    PRIMARY KEY (title_id, genre_id)                             -- a title has a genre at most once
);


-- ---------------------------------------------------------------------
-- 7. episodes: episodes of each series
-- ---------------------------------------------------------------------
CREATE TABLE episodes (
    episode_id     INTEGER       PRIMARY KEY,                    -- surrogate key used by viewing_activity
    title_id       INTEGER       NOT NULL
                   REFERENCES titles (title_id) ON DELETE RESTRICT,  -- don't lose episodes that have history
    season_no      SMALLINT      NOT NULL,
    episode_no     SMALLINT      NOT NULL,
    episode_title  VARCHAR(200)  NOT NULL,
    runtime_min    SMALLINT      NOT NULL,
    release_date   DATE          NOT NULL,

    -- natural key: an episode is identified by (series, season, episode number)
    CONSTRAINT uq_episodes_series_season_ep UNIQUE (title_id, season_no, episode_no),
    -- needed only as the target of the composite FK in viewing_activity (see there)
    CONSTRAINT uq_episodes_id_title         UNIQUE (episode_id, title_id),
    CONSTRAINT chk_episodes_season          CHECK (season_no >= 1),
    CONSTRAINT chk_episodes_number          CHECK (episode_no >= 1),
    CONSTRAINT chk_episodes_runtime         CHECK (runtime_min BETWEEN 1 AND 300)
);


-- ---------------------------------------------------------------------
-- 8. viewing_activity: every play (the big, fast-growing fact table)
-- ---------------------------------------------------------------------
CREATE TABLE viewing_activity (
    view_id               INTEGER      PRIMARY KEY,
    profile_id            INTEGER      NOT NULL
                          REFERENCES profiles (profile_id) ON DELETE CASCADE,  -- history belongs to the profile
    title_id              INTEGER      NOT NULL
                          REFERENCES titles (title_id) ON DELETE RESTRICT,     -- keep analytics history
    episode_id            INTEGER,                               -- NULL for movies (they have no episodes)
    started_at            TIMESTAMPTZ  NOT NULL,
    duration_watched_sec  INTEGER      NOT NULL,
    device_type           VARCHAR(6)   NOT NULL,
    completed             BOOLEAN      NOT NULL,

    -- Composite FK: the episode must belong to the SAME series as title_id.
    -- MATCH SIMPLE (default) skips the check when episode_id IS NULL (movies).
    CONSTRAINT fk_viewing_episode_of_title
        FOREIGN KEY (episode_id, title_id)
        REFERENCES episodes (episode_id, title_id) ON DELETE RESTRICT,
    CONSTRAINT chk_viewing_duration  CHECK (duration_watched_sec > 0),
    CONSTRAINT chk_viewing_device    CHECK (device_type IN ('TV', 'MOBILE', 'LAPTOP', 'TABLET'))
);


-- ---------------------------------------------------------------------
-- 9. ratings: one rating per profile per title
-- ---------------------------------------------------------------------
CREATE TABLE ratings (
    profile_id  INTEGER      NOT NULL
                REFERENCES profiles (profile_id) ON DELETE CASCADE,
    title_id    INTEGER      NOT NULL
                REFERENCES titles (title_id) ON DELETE CASCADE,
    rating      VARCHAR(11)  NOT NULL,
    rated_at    TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (profile_id, title_id),                          -- re-rating replaces, never duplicates
    CONSTRAINT chk_ratings_value CHECK (rating IN ('THUMBS_DOWN', 'THUMBS_UP', 'LOVE'))
);


-- ---------------------------------------------------------------------
-- 10. my_list: titles saved by each profile
-- ---------------------------------------------------------------------
CREATE TABLE my_list (
    profile_id  INTEGER      NOT NULL
                REFERENCES profiles (profile_id) ON DELETE CASCADE,
    title_id    INTEGER      NOT NULL
                REFERENCES titles (title_id) ON DELETE CASCADE,
    added_at    TIMESTAMPTZ  NOT NULL,
    PRIMARY KEY (profile_id, title_id)                           -- W02 relies on this: ON CONFLICT (profile_id, title_id)
);


-- ---------------------------------------------------------------------
-- 11. invoices: one invoice per account per month
-- ---------------------------------------------------------------------
CREATE TABLE invoices (
    invoice_id            INTEGER       PRIMARY KEY,
    account_id            INTEGER       NOT NULL
                          REFERENCES accounts (account_id) ON DELETE RESTRICT,  -- financial records are never deleted
    billing_period_start  DATE          NOT NULL,
    amount_inr            NUMERIC(8,2)  NOT NULL,                -- copied from the plan price AT billing time
    status                VARCHAR(8)    NOT NULL,
    paid_at               TIMESTAMPTZ,                           -- NULL when the payment failed

    CONSTRAINT uq_invoices_account_period  UNIQUE (account_id, billing_period_start),
    CONSTRAINT chk_invoices_status         CHECK (status IN ('PAID', 'FAILED', 'REFUNDED')),
    -- failed invoices have no payment time; PAID / REFUNDED ones always do
    CONSTRAINT chk_invoices_paid_at        CHECK ((status = 'FAILED') = (paid_at IS NULL)),
    -- invoices always start on the 1st of a month
    CONSTRAINT chk_invoices_first_of_month CHECK (EXTRACT(DAY FROM billing_period_start) = 1),
    CONSTRAINT chk_invoices_amount         CHECK (amount_inr > 0)
);


-- =====================================================================
-- Indexes that exist after this script (ALL created automatically by
-- PRIMARY KEY / UNIQUE constraints; no manual index yet):
--   plans_pkey, plans_plan_name_key
--   genres_pkey, genres_genre_name_key
--   accounts_pkey, accounts_email_key, accounts_phone_key
--   profiles_pkey, uq_profiles_account_name (account_id, profile_name)
--   titles_pkey
--   title_genres_pkey (title_id, genre_id)
--   episodes_pkey, uq_episodes_series_season_ep (title_id, season_no, episode_no),
--   uq_episodes_id_title (episode_id, title_id)
--   viewing_activity_pkey
--   ratings_pkey (profile_id, title_id)
--   my_list_pkey (profile_id, title_id)
--   invoices_pkey, uq_invoices_account_period (account_id, billing_period_start)
-- Check with:  SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'netflix';
-- =====================================================================
