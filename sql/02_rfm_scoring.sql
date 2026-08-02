-- ============================================================
-- 02_rfm_scoring.sql
-- RFM Scoring — Recency, Frequency, Monetary
-- Run each query separately: select it and press Ctrl+E, E
-- ============================================================


-- ── 2.1 RECENCY ──────────────────────────────────────────────

-- Step 1: Days since last purchase per customer
SELECT
    customer_id,
    MAX(purchase_date)                                AS last_purchase_date,
    ('2024-12-31'::date - MAX(purchase_date))         AS days_since_last_purchase
FROM purchases
GROUP BY customer_id
ORDER BY customer_id ASC;

-- Step 2: Assign recency score 1–5
-- Ranges are manually set for better control.
-- Lower days since last purchase = higher score.
SELECT
    customer_id,
    last_purchase_date,
    days_since_last_purchase,
    CASE
        WHEN days_since_last_purchase <= 30  THEN 5
        WHEN days_since_last_purchase <= 90  THEN 4
        WHEN days_since_last_purchase <= 180 THEN 3
        WHEN days_since_last_purchase <= 365 THEN 2
        ELSE 1
    END AS recency_score
FROM (
    SELECT
        customer_id,
        MAX(purchase_date)                            AS last_purchase_date,
        ('2024-12-31'::date - MAX(purchase_date))     AS days_since_last_purchase
    FROM purchases
    GROUP BY customer_id
) AS recency_base
ORDER BY customer_id ASC;


-- ── 2.2 FREQUENCY ────────────────────────────────────────────

-- Total purchases per customer + NTILE(5) score.
-- Higher purchase count = higher score.
SELECT
    customer_id,
    COUNT(purchase_id)                                        AS total_purchases,
    NTILE(5) OVER (ORDER BY COUNT(purchase_id) ASC)           AS frequency_score
FROM purchases
GROUP BY customer_id
ORDER BY customer_id ASC;


-- ── 2.3 MONETARY ─────────────────────────────────────────────

-- Total amount paid per customer + NTILE(5) score.
-- Higher total spend = higher score.
SELECT
    customer_id,
    ROUND(SUM(amount_paid)::numeric, 2)                       AS total_spent,
    NTILE(5) OVER (ORDER BY SUM(amount_paid) ASC)             AS monetary_score
FROM purchases
GROUP BY customer_id
ORDER BY customer_id ASC;


-- ── 2.4 RFM SCORE ────────────────────────────────────────────

-- Combines recency, frequency and monetary into a single RFM score.
WITH
recency AS (
    SELECT
        customer_id,
        last_purchase_date,
        days_since_last_purchase,
        CASE
            WHEN days_since_last_purchase <= 30  THEN 5
            WHEN days_since_last_purchase <= 90  THEN 4
            WHEN days_since_last_purchase <= 180 THEN 3
            WHEN days_since_last_purchase <= 365 THEN 2
            ELSE 1
        END AS r_score
    FROM (
        SELECT
            customer_id,
            MAX(purchase_date)                                AS last_purchase_date,
            ('2024-12-31'::date - MAX(purchase_date))         AS days_since_last_purchase
        FROM purchases
        GROUP BY customer_id
    ) AS recency_base
),

frequency AS (
    SELECT
        customer_id,
        COUNT(purchase_id)                                    AS total_purchases,
        NTILE(5) OVER (ORDER BY COUNT(purchase_id) ASC)       AS f_score
    FROM purchases
    GROUP BY customer_id
),

monetary AS (
    SELECT
        customer_id,
        ROUND(SUM(amount_paid)::numeric, 2)                   AS total_spent,
        NTILE(5) OVER (ORDER BY SUM(amount_paid) ASC)         AS m_score
    FROM purchases
    GROUP BY customer_id
)

SELECT
    recency.customer_id,
    recency.last_purchase_date,
    recency.days_since_last_purchase,
    recency.r_score,
    frequency.total_purchases,
    frequency.f_score,
    monetary.total_spent,
    monetary.m_score,
    (recency.r_score + frequency.f_score + monetary.m_score)  AS rfm_score
FROM recency
INNER JOIN frequency USING (customer_id)
INNER JOIN monetary  USING (customer_id)
ORDER BY rfm_score DESC;
