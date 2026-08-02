-- ============================================================
-- 01_data_validation.sql
-- Data Validation and Processing
-- Run each query separately: select it and press Ctrl+E, E
-- ============================================================


-- ── 1.1 CHECKING DATE CONSISTENCY ────────────────────────────

-- Verifying that no login session occurred before the customer's joining date.
SELECT logins.login_date, customers.joining_date, customers.customer_id
FROM customers
INNER JOIN logins
    ON customers.customer_id = logins.customer_id
WHERE logins.login_date < customers.joining_date;

-- Verifying that no course completion date occurred before its purchase date.
SELECT purchases.purchase_date, assessments.completion_date,
       assessments.course_id, assessments.customer_id
FROM purchases
INNER JOIN assessments
    ON assessments.customer_id = purchases.customer_id
   AND assessments.course_id = purchases.course_id
-- Excludes NULL completion dates (incomplete courses) by default
WHERE assessments.completion_date < purchases.purchase_date;


-- ── 1.2 SEARCHING FOR NULLs ──────────────────────────────────

-- Customers Table
SELECT COUNT(*) AS joining_nulls
FROM customers
WHERE joining_date IS NULL;

-- Purchases Table
SELECT COUNT(*) AS purchases_nulls
FROM purchases
WHERE customer_id IS NULL
   OR course_id IS NULL
   OR purchase_date IS NULL
   OR amount_paid IS NULL;

-- Login Sessions Table
SELECT COUNT(*) AS logins_nulls
FROM logins
WHERE customer_id IS NULL
   OR course_id IS NULL
   OR login_date IS NULL
   OR login_duration IS NULL;

-- Assessments Table — crucial fields
SELECT COUNT(*) AS assessments_nulls
FROM assessments
WHERE customer_id IS NULL
   OR course_id IS NULL
   OR completion_rate IS NULL;

-- Assessments Table — rating (nullable by design)
SELECT COUNT(*) AS rating_nulls
FROM assessments
WHERE rating IS NULL;

-- Assessments Table — completion_date (nullable by design)
SELECT COUNT(*) AS completion_date_nulls
FROM assessments
WHERE completion_date IS NULL;


-- ── 1.3 ORPHANED RECORDS ─────────────────────────────────────

-- Verifying that no login session record exists without a corresponding purchase.
SELECT logins.customer_id, logins.course_id, logins.login_id, purchases.purchase_id
FROM logins
LEFT JOIN purchases
    USING (customer_id, course_id)
WHERE purchases.purchase_id IS NULL;

-- Verifying that no assessment record exists without a corresponding purchase.
SELECT assessments.customer_id, assessments.course_id,
       assessments.assessment_id, purchases.purchase_id
FROM assessments
LEFT JOIN purchases
    USING (customer_id, course_id)
WHERE purchases.purchase_id IS NULL;


-- ── 1.4 COMPLETION RATE AND RATING PER COURSE ────────────────

SELECT
    assessments.course_id,
    courses.course_name,
    ROUND(AVG(rating), 2)           AS avg_rating,
    ROUND(AVG(completion_rate), 2)  AS avg_completion_rate
FROM assessments
INNER JOIN courses ON assessments.course_id = courses.course_id
WHERE rating IS NOT NULL
GROUP BY assessments.course_id, courses.course_name
ORDER BY assessments.course_id ASC;


-- ── 1.5 CUSTOMER JOINING DISTRIBUTION OVER TIME ──────────────

SELECT
    TO_CHAR(joining_date, 'YYYY-"Q"Q') AS quarter,
    COUNT(customer_id)                  AS new_customers
FROM customers
GROUP BY quarter
ORDER BY quarter ASC;


-- ── 1.6 BASIC STATISTICAL DATA ───────────────────────────────

SELECT
    COUNT(DISTINCT customer_id) AS total_customers,
    COUNT(*)                    AS total_purchases,
    ROUND(AVG(amount_paid), 2)  AS avg_order_value,
    MIN(purchase_date)          AS first_purchase,
    MAX(purchase_date)          AS last_purchase
FROM purchases;


-- ── 1.7 MOST AND LEAST POPULAR COURSES ───────────────────────

SELECT
    courses.course_name,
    courses.course_category,
    COUNT(purchases.course_id)                                  AS course_total_purchases,
    RANK() OVER (ORDER BY COUNT(purchases.course_id) DESC)      AS rank
FROM purchases
INNER JOIN courses USING (course_id)
GROUP BY courses.course_name, courses.course_category
ORDER BY rank ASC;
