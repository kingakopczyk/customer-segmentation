-- =====================================================================
-- 00_SCHEMA.SQL  |  "Who Learns Online?" – fave. online design platform
-- =====================================================================
-- PURPOSE : create the five tables (types, primary/foreign keys, CHECKs)
--           and load the CSV files from data/generated_data/.
-- ENGINE  : PostgreSQL 14+ (tested on 16).
-- RUN     : once, on an empty database, BEFORE 01_data_validation.sql.
--
-- WARNING : the DROP statement below deletes the five tables WITH ALL THEIR
--           DATA and every view built on top of them (CASCADE). After
--           re-running this file, load the five CSV files again (see LOAD
--           THE DATA below) and run 02 and 03 again to recreate the views.
--
-- DESIGN NOTES
--   * (customer_id, course_id) is UNIQUE in purchases: a customer buys a
--     given course at most once. assessments and logins reference that
--     pair, so every assessment/login is guaranteed to belong to a real
--     purchase (no orphans) and JOINs on the pair can never duplicate rows.
--   * CHECK constraints reject out-of-range values at import time
--     (rating 1-5, completion_rate 0-1, positive prices and durations).
--     01_data_validation.sql re-tests all of this explicitly, so the
--     project is still verifiable if the tables were created differently.
--   * rating and completion_date are nullable BY DESIGN: not every learner
--     leaves a rating, and not every course reaches a completion date.
-- =====================================================================

DROP TABLE IF EXISTS logins, assessments, purchases, courses, customers CASCADE;

CREATE TABLE customers (
    customer_id   VARCHAR(10) PRIMARY KEY,
    joining_date  DATE        NOT NULL
);

CREATE TABLE courses (
    course_id        VARCHAR(10)  PRIMARY KEY,
    course_name      TEXT         NOT NULL,
    course_category  TEXT         NOT NULL,
    course_price     NUMERIC(8,2) NOT NULL CHECK (course_price > 0),
    margin_pct       NUMERIC(4,2) NOT NULL CHECK (margin_pct BETWEEN 0 AND 1),
    profit_per_sale  NUMERIC(8,2) NOT NULL,
    cogs_per_sale    NUMERIC(8,2) NOT NULL CHECK (cogs_per_sale >= 0)
);

CREATE TABLE purchases (
    purchase_id    VARCHAR(10)  PRIMARY KEY,
    customer_id    VARCHAR(10)  NOT NULL REFERENCES customers (customer_id),
    course_id      VARCHAR(10)  NOT NULL REFERENCES courses (course_id),
    purchase_date  DATE         NOT NULL,
    amount_paid    NUMERIC(8,2) NOT NULL CHECK (amount_paid > 0),
    CONSTRAINT uq_purchases_customer_course UNIQUE (customer_id, course_id)
);

CREATE TABLE assessments (
    assessment_id    VARCHAR(10)  PRIMARY KEY,
    customer_id      VARCHAR(10)  NOT NULL,
    course_id        VARCHAR(10)  NOT NULL,
    completion_rate  NUMERIC(3,2) NOT NULL CHECK (completion_rate BETWEEN 0 AND 1),
    rating           NUMERIC(2,1)          CHECK (rating BETWEEN 1 AND 5),
    completion_date  DATE,
    FOREIGN KEY (customer_id, course_id) REFERENCES purchases (customer_id, course_id)
);

CREATE TABLE logins (
    login_id        VARCHAR(10) PRIMARY KEY,
    customer_id     VARCHAR(10) NOT NULL,
    course_id       VARCHAR(10) NOT NULL,
    login_date      DATE        NOT NULL,
    login_duration  INTEGER     NOT NULL CHECK (login_duration > 0),   -- minutes
    FOREIGN KEY (customer_id, course_id) REFERENCES purchases (customer_id, course_id)
);

-- Indexes that speed up the per-customer aggregations in 02-03
CREATE INDEX idx_purchases_customer ON purchases (customer_id, purchase_date);
CREATE INDEX idx_logins_customer    ON logins    (customer_id, login_date);

-- ---------------------------------------------------------------------
-- LOAD THE DATA (order matters because of the foreign keys)
-- ---------------------------------------------------------------------
-- Option A - pgAdmin: right-click each table > Import/Export Data...
--            Format: csv | Header: ON | Delimiter: ,   (order below)
-- Option B - psql (run from the repository root):
--   \copy customers   FROM 'data/generated_data/customers.csv'   CSV HEADER
--   \copy courses     FROM 'data/generated_data/courses.csv'     CSV HEADER
--   \copy purchases   FROM 'data/generated_data/purchases.csv'   CSV HEADER
--   \copy assessments FROM 'data/generated_data/assessments.csv' CSV HEADER
--   \copy logins      FROM 'data/generated_data/logins.csv'      CSV HEADER
--
-- Expected row counts after the import: customers 1 000 | courses 15 |
-- purchases 5 217 | assessments 5 217 | logins 51 609

-- =====================================================================
-- ANALYSIS PARAMETER  (safe to run on its own, e.g. if the tables
-- already exist and you do not want to reload them)
-- =====================================================================
-- Every "days since ..." measure in 02-04 is computed against this
-- snapshot date (the last day covered by the data), NEVER CURRENT_DATE,
-- so the results are identical no matter when the queries are run.
-- It is defined here once; change it here only.
CREATE OR REPLACE VIEW v_params AS
SELECT DATE '2024-12-31' AS snapshot_date;
