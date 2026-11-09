-- =====================================================================
-- 02_RFM_SCORING.SQL  |  Recency, Frequency and Monetary scores
-- =====================================================================
-- RUN     : 2.1 as a whole (it creates the view v_rfm), then 2.2-2.4 one
--           by one (select a query and press Ctrl+E, E).
-- REQUIRES: 00_schema.sql (tables + v_params).
--
-- WHY FIXED THRESHOLDS INSTEAD OF NTILE
--   NTILE(5) cuts customers into five equal-sized groups. Purchase counts
--   are discrete (1, 2, 3 ...) so many customers are tied, and NTILE then
--   separates tied customers ARBITRARILY: two customers with the same
--   number of purchases could get different scores, and the result changed
--   with the physical row order. Fixed thresholds guarantee that identical
--   customers always receive identical scores, make every later rule
--   readable ("3+ purchases") and make the whole analysis reproducible.
--
-- SCORING THRESHOLDS
--   score | Recency: days since    | Frequency: number of | Monetary: total
--         | the last purchase      | purchases            | spent
--   ------+------------------------+----------------------+----------------
--     5   | <= 30                  | 8 or more            | $500 or more
--     4   | 31 - 90                | 5 - 7                | $350 - 499
--     3   | 91 - 180               | 3 - 4                | $250 - 349
--     2   | 181 - 365              | 2                    | $150 - 249
--     1   | > 365                  | 1                    | below $150
--
--   How the cut-offs were chosen (they are NOT all quintiles):
--     R  business time periods: a month, a quarter, half a year, a year.
--        Customers are not spread evenly (see 2.3) - that is intended.
--     F  business meaning: 1 = one-off buyer, 2 = second purchase,
--        3-4 = repeat buyer, 5-7 = frequent buyer, 8+ = heavy buyer.
--        The segmentation rules in 03 rely on "3+ purchases" = repeat buyer.
--     M  near-quintile cut-offs rounded to whole $50 (about 20% of the
--        customers per score), chosen after inspecting the 2022-2024
--        distribution of total_spent.
--
-- rfm_score = r_score + f_score + m_score (range 3-15, equal weights).
-- References: Hughes (1994) for the RFM scoring idea; Fader, Hardie & Lee
-- (2005) is a probabilistic (BG/NBD) alternative and a possible next step.
-- =====================================================================


-- ── 2.1 VIEW v_rfm : ONE ROW PER CUSTOMER WITH R, F AND M SCORES ─────

DROP VIEW IF EXISTS v_rfm CASCADE;   -- CASCADE also drops views built on it (03)

CREATE VIEW v_rfm AS
WITH purchase_base AS (
    SELECT
        customer_id,
        MIN(purchase_date)                      AS first_purchase_date,
        MAX(purchase_date)                      AS last_purchase_date,
        COUNT(purchase_id)                      AS total_purchases,
        ROUND(SUM(amount_paid)::numeric, 2)     AS total_spent
    FROM purchases
    GROUP BY customer_id
),
scored AS (
    SELECT
        b.customer_id,
        b.first_purchase_date,
        b.last_purchase_date,
        (s.snapshot_date - b.first_purchase_date)   AS days_since_first_purchase,
        (s.snapshot_date - b.last_purchase_date)    AS days_since_last_purchase,

        -- RECENCY
        CASE
            WHEN s.snapshot_date - b.last_purchase_date <= 30  THEN 5
            WHEN s.snapshot_date - b.last_purchase_date <= 90  THEN 4
            WHEN s.snapshot_date - b.last_purchase_date <= 180 THEN 3
            WHEN s.snapshot_date - b.last_purchase_date <= 365 THEN 2
            ELSE 1
        END                                         AS r_score,

        b.total_purchases,
        -- FREQUENCY
        CASE
            WHEN b.total_purchases >= 8 THEN 5
            WHEN b.total_purchases >= 5 THEN 4
            WHEN b.total_purchases >= 3 THEN 3
            WHEN b.total_purchases  = 2 THEN 2
            ELSE 1
        END                                         AS f_score,

        b.total_spent,
        -- MONETARY
        CASE
            WHEN b.total_spent >= 500 THEN 5
            WHEN b.total_spent >= 350 THEN 4
            WHEN b.total_spent >= 250 THEN 3
            WHEN b.total_spent >= 150 THEN 2
            ELSE 1
        END                                         AS m_score
    FROM purchase_base b
    CROSS JOIN v_params s
)
SELECT
    customer_id,
    first_purchase_date,
    last_purchase_date,
    days_since_first_purchase,
    days_since_last_purchase,
    r_score,
    total_purchases,
    f_score,
    total_spent,
    m_score,
    (r_score + f_score + m_score)                   AS rfm_score
FROM scored;


-- ── 2.2 PREVIEW: TOP CUSTOMERS BY RFM SCORE ──────────────────────────

SELECT *
FROM v_rfm
ORDER BY rfm_score DESC, customer_id
LIMIT 10;


-- ── 2.3 SCORE DISTRIBUTIONS (share of customers per score) ───────────
-- No score should be empty and none should swallow most customers.

SELECT dimension, score, customers,
       ROUND(100.0 * customers / SUM(customers) OVER (PARTITION BY dimension), 1) AS pct
FROM (
    SELECT 'R' AS dimension, r_score AS score, COUNT(*) AS customers FROM v_rfm GROUP BY r_score
    UNION ALL
    SELECT 'F', f_score, COUNT(*) FROM v_rfm GROUP BY f_score
    UNION ALL
    SELECT 'M', m_score, COUNT(*) FROM v_rfm GROUP BY m_score
) AS d
ORDER BY CASE dimension WHEN 'R' THEN 1 WHEN 'F' THEN 2 ELSE 3 END, score DESC;


-- ── 2.4 DETERMINISM CHECK ────────────────────────────────────────────
-- (a) Customers with the same number of purchases must share one f_score
--     (this is exactly what NTILE could not guarantee). Must return 0.

SELECT COUNT(*) AS purchase_counts_with_more_than_one_f_score
FROM (
    SELECT total_purchases
    FROM v_rfm
    GROUP BY total_purchases
    HAVING COUNT(DISTINCT f_score) > 1
) AS ties;

-- (b) Observed value range of each score: ranges must not overlap.

SELECT 'R (days since last purchase)' AS dimension, r_score AS score,
       MIN(days_since_last_purchase) AS min_value, MAX(days_since_last_purchase) AS max_value
FROM v_rfm GROUP BY r_score
UNION ALL
SELECT 'F (purchases)', f_score, MIN(total_purchases), MAX(total_purchases)
FROM v_rfm GROUP BY f_score
UNION ALL
SELECT 'M (total spent, $)', m_score, MIN(total_spent), MAX(total_spent)
FROM v_rfm GROUP BY m_score
ORDER BY dimension, score DESC;


-- ── 2.5 WHY NOT NTILE: A DEMONSTRATION (informational) ───────────────
-- Frequency scored with NTILE(5) instead of fixed thresholds. Purchase counts
-- that sit on a bucket boundary are split between two scores, so customers
-- with exactly the same number of purchases receive different scores - and
-- which customer gets which score depends on the physical row order.
-- Result in this dataset: 3, 4, 6 and 8 purchases are all split (445 customers
-- = 44.5%). The fixed thresholds of 2.1 cannot do this (see 2.4a).

WITH s AS (
    SELECT customer_id, total_purchases,
           NTILE(5) OVER (ORDER BY total_purchases) AS f_ntile
    FROM v_rfm
)
SELECT total_purchases,
       COUNT(*)        AS customers,
       MIN(f_ntile)    AS lowest_ntile_score,
       MAX(f_ntile)    AS highest_ntile_score
FROM s
GROUP BY total_purchases
HAVING COUNT(DISTINCT f_ntile) > 1
ORDER BY total_purchases;
