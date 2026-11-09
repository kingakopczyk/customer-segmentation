-- =====================================================================
-- 01_DATA_VALIDATION.SQL  |  Data validation and profiling
-- =====================================================================
-- RUN     : query by query - select a query and press Ctrl+E, E.
-- REQUIRES: 00_schema.sql AND the five CSV files loaded into the tables.
--           Start with 1.0: on empty tables every check in 1.1 passes
--           vacuously.
-- NOTE    : 00_schema.sql already enforces keys, ranges and uniqueness at
--           import time. Section 1.1 re-tests all of it explicitly (so the
--           project stays verifiable even if the tables were created in a
--           different way) and adds the checks a constraint cannot express,
--           e.g. date logic across tables.
-- =====================================================================


-- ── 1.0 ROW COUNTS: ARE THE TABLES LOADED? ────────────────────────────
-- Run this first. A table with 0 rows means its CSV was not imported, the
-- import failed, or 00_schema.sql was re-run afterwards (it drops and
-- recreates every table EMPTY). Nothing below makes sense on empty tables.
-- shipped_dataset = row counts of the CSV files in data/generated_data/;
-- data generated again with the notebook has other counts, which is fine.

SELECT table_name, actual_rows, shipped_dataset,
       CASE WHEN actual_rows = 0 THEN 'EMPTY - load the CSV file (see 00_schema.sql)'
            ELSE 'OK' END AS status
FROM (
    SELECT 1 AS ord, 'customers' AS table_name,
           COUNT(*) AS actual_rows, 1000 AS shipped_dataset
    FROM customers
    UNION ALL
    SELECT 2, 'courses', COUNT(*), 15 FROM courses
    UNION ALL
    SELECT 3, 'purchases', COUNT(*), 5217 FROM purchases
    UNION ALL
    SELECT 4, 'assessments', COUNT(*), 5217 FROM assessments
    UNION ALL
    SELECT 5, 'logins', COUNT(*), 51609 FROM logins
) AS counts
ORDER BY ord;


-- ── 1.1 INTEGRITY SUMMARY ─────────────────────────────────────────────
-- One row per check. Every row must show violations = 0 / status = OK.
-- Only meaningful on loaded tables (see 1.0): an empty database passes all 23.

SELECT check_group, check_name, violations,
       CASE WHEN violations = 0 THEN 'OK' ELSE 'CHECK' END AS status
FROM (
    -- dates ------------------------------------------------------------
    SELECT 1 AS ord, 'dates' AS check_group,
           'purchase before the customer joined' AS check_name, COUNT(*) AS violations
    FROM purchases p JOIN customers c USING (customer_id)
    WHERE p.purchase_date < c.joining_date
    UNION ALL
    SELECT 2, 'dates', 'login before the customer joined', COUNT(*)
    FROM logins l JOIN customers c USING (customer_id)
    WHERE l.login_date < c.joining_date
    UNION ALL
    SELECT 3, 'dates', 'login before the purchase of that course', COUNT(*)
    FROM logins l JOIN purchases p USING (customer_id, course_id)
    WHERE l.login_date < p.purchase_date
    UNION ALL
    SELECT 4, 'dates', 'completion_date before the purchase date', COUNT(*)
    FROM assessments a JOIN purchases p USING (customer_id, course_id)
    WHERE a.completion_date < p.purchase_date          -- NULL dates are skipped by design
    UNION ALL
    SELECT 5, 'dates', 'purchase / login / completion after the snapshot date',
           (SELECT COUNT(*) FROM purchases,   v_params WHERE purchase_date   > snapshot_date)
         + (SELECT COUNT(*) FROM logins,      v_params WHERE login_date      > snapshot_date)
         + (SELECT COUNT(*) FROM assessments, v_params WHERE completion_date > snapshot_date)
    -- referential integrity -------------------------------------------
    UNION ALL
    SELECT 6, 'referential', 'purchases without a customer', COUNT(*)
    FROM purchases p LEFT JOIN customers c USING (customer_id)
    WHERE c.customer_id IS NULL
    UNION ALL
    SELECT 7, 'referential', 'purchases without a course', COUNT(*)
    FROM purchases p LEFT JOIN courses c USING (course_id)
    WHERE c.course_id IS NULL
    UNION ALL
    SELECT 8, 'referential', 'logins without a matching purchase', COUNT(*)
    FROM logins l LEFT JOIN purchases p USING (customer_id, course_id)
    WHERE p.purchase_id IS NULL
    UNION ALL
    SELECT 9, 'referential', 'assessments without a matching purchase', COUNT(*)
    FROM assessments a LEFT JOIN purchases p USING (customer_id, course_id)
    WHERE p.purchase_id IS NULL
    UNION ALL
    SELECT 10, 'referential', 'customers without any purchase', COUNT(*)
    FROM customers c
    WHERE NOT EXISTS (SELECT 1 FROM purchases p WHERE p.customer_id = c.customer_id)
    UNION ALL
    SELECT 11, 'referential', 'purchases without an assessment record', COUNT(*)
    FROM purchases p LEFT JOIN assessments a USING (customer_id, course_id)
    WHERE a.assessment_id IS NULL
    -- uniqueness ------------------------------------------------------
    UNION ALL
    SELECT 12, 'uniqueness', 'customer bought the same course twice', COUNT(*)
    FROM (SELECT customer_id, course_id FROM purchases
          GROUP BY customer_id, course_id HAVING COUNT(*) > 1) d
    UNION ALL
    SELECT 13, 'uniqueness', 'more than one assessment per purchase', COUNT(*)
    FROM (SELECT customer_id, course_id FROM assessments
          GROUP BY customer_id, course_id HAVING COUNT(*) > 1) d
    -- value ranges ----------------------------------------------------
    UNION ALL
    SELECT 14, 'ranges', 'rating outside 1-5', COUNT(*)
    FROM assessments WHERE rating < 1 OR rating > 5
    UNION ALL
    SELECT 15, 'ranges', 'completion_rate outside 0-1', COUNT(*)
    FROM assessments WHERE completion_rate < 0 OR completion_rate > 1
    UNION ALL
    SELECT 16, 'ranges', 'login_duration <= 0 minutes', COUNT(*)
    FROM logins WHERE login_duration <= 0
    UNION ALL
    SELECT 17, 'ranges', 'amount_paid differs from course_price', COUNT(*)
    FROM purchases p JOIN courses c USING (course_id)
    WHERE p.amount_paid <> c.course_price
    UNION ALL
    SELECT 18, 'ranges', 'profit_per_sale <> course_price - cogs_per_sale', COUNT(*)
    FROM courses
    WHERE ABS(profit_per_sale - (course_price - cogs_per_sale)) > 0.01
    -- NULLs in mandatory fields ---------------------------------------
    UNION ALL
    SELECT 19, 'nulls', 'customers: NULL in a mandatory field', COUNT(*)
    FROM customers WHERE customer_id IS NULL OR joining_date IS NULL
    UNION ALL
    SELECT 20, 'nulls', 'courses: NULL in any field', COUNT(*)
    FROM courses
    WHERE course_name IS NULL OR course_category IS NULL OR course_price IS NULL
       OR margin_pct IS NULL OR profit_per_sale IS NULL OR cogs_per_sale IS NULL
    UNION ALL
    SELECT 21, 'nulls', 'purchases: NULL in any field', COUNT(*)
    FROM purchases
    WHERE customer_id IS NULL OR course_id IS NULL OR purchase_date IS NULL OR amount_paid IS NULL
    UNION ALL
    SELECT 22, 'nulls', 'assessments: NULL in a mandatory field', COUNT(*)
    FROM assessments
    WHERE customer_id IS NULL OR course_id IS NULL OR completion_rate IS NULL
    UNION ALL
    SELECT 23, 'nulls', 'logins: NULL in any field', COUNT(*)
    FROM logins
    WHERE customer_id IS NULL OR course_id IS NULL OR login_date IS NULL OR login_duration IS NULL
) AS checks
ORDER BY ord;


-- ── 1.2 NULLs THAT ARE NULLABLE BY DESIGN ─────────────────────────────
-- A learner may skip the rating, and a course may have no completion date.
-- NULLIF(COUNT(*), 0) turns the percentages into NULL instead of failing
-- with "division by zero" when assessments is empty (see 1.0).

SELECT
    COUNT(*)                                                    AS assessments,
    COUNT(*) FILTER (WHERE rating IS NULL)                      AS rating_nulls,
    ROUND(100.0 * COUNT(*) FILTER (WHERE rating IS NULL)
                / NULLIF(COUNT(*), 0), 1)                       AS rating_null_pct,
    COUNT(*) FILTER (WHERE completion_date IS NULL)             AS completion_date_nulls,
    ROUND(100.0 * COUNT(*) FILTER (WHERE completion_date IS NULL)
                / NULLIF(COUNT(*), 0), 1)                       AS completion_date_null_pct
FROM assessments;


-- ── 1.3 KNOWN DATA LIMITATION (informational, not an error) ──────────
-- completion_date and the login sessions were generated independently,
-- so some courses show a completion date BEFORE their first login.
-- It does not affect the segmentation (which uses completion_rate and
-- login counts/durations, not these dates) but is documented in the README.

SELECT
    COUNT(*) FILTER (WHERE a.completion_date IS NOT NULL)       AS completion_dates,
    COUNT(*) FILTER (WHERE a.completion_date < fl.first_login)  AS completion_before_first_login,
    ROUND(100.0 * COUNT(*) FILTER (WHERE a.completion_date < fl.first_login)
                / NULLIF(COUNT(*) FILTER (WHERE a.completion_date IS NOT NULL), 0), 1) AS pct
FROM assessments a
JOIN (SELECT customer_id, course_id, MIN(login_date) AS first_login
      FROM logins GROUP BY customer_id, course_id) fl USING (customer_id, course_id);


-- ── 1.4 COMPLETION RATE AND RATING PER COURSE ────────────────────────
-- avg_completion_rate covers ALL assessments; AVG(rating) ignores NULLs
-- on its own, so no WHERE rating IS NOT NULL (it would bias completion).

SELECT
    a.course_id,
    c.course_name,
    COUNT(*)                                          AS assessments,
    ROUND(100.0 * COUNT(a.rating) / COUNT(*), 1)      AS rated_pct,
    ROUND(AVG(a.rating)::numeric, 2)                  AS avg_rating,
    ROUND(AVG(a.completion_rate)::numeric, 2)         AS avg_completion_rate
FROM assessments a
INNER JOIN courses c USING (course_id)
GROUP BY a.course_id, c.course_name
ORDER BY a.course_id ASC;


-- ── 1.5 CUSTOMER JOINING DISTRIBUTION OVER TIME ──────────────────────

SELECT
    TO_CHAR(joining_date, 'YYYY-"Q"Q') AS quarter,
    COUNT(customer_id)                 AS new_customers
FROM customers
GROUP BY quarter
ORDER BY quarter ASC;


-- ── 1.6 BASIC STATISTICAL DATA ───────────────────────────────────────

SELECT
    (SELECT COUNT(*) FROM customers)                      AS customers,
    (SELECT COUNT(*) FROM purchases)                      AS purchases,
    (SELECT COUNT(*) FROM assessments)                    AS assessments,
    (SELECT COUNT(*) FROM logins)                         AS login_sessions,
    (SELECT ROUND(AVG(amount_paid)::numeric, 2) FROM purchases) AS avg_order_value,
    (SELECT MIN(purchase_date) FROM purchases)            AS first_purchase,
    (SELECT MAX(purchase_date) FROM purchases)            AS last_purchase,
    (SELECT MAX(login_date)    FROM logins)               AS last_login;


-- ── 1.7 MOST AND LEAST POPULAR COURSES ───────────────────────────────

SELECT
    c.course_name,
    c.course_category,
    COUNT(p.course_id)                                     AS course_total_purchases,
    RANK() OVER (ORDER BY COUNT(p.course_id) DESC)         AS rank
FROM purchases p
INNER JOIN courses c USING (course_id)
GROUP BY c.course_name, c.course_category
ORDER BY rank ASC, c.course_name;
