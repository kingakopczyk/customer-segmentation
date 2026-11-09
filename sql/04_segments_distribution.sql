-- =====================================================================
-- 04_SEGMENTS_DISTRIBUTION.SQL  |  Segment sizes, profiles and diagnostics
-- =====================================================================
-- RUN     : query by query - select a query and press Ctrl+E, E.
-- REQUIRES: 03_segmentation.sql (view v_customer_segments).
-- All queries read the view, so nothing here repeats the segment rules.
-- =====================================================================


-- ── 4.1 SEGMENT DISTRIBUTION ─────────────────────────────────────────
-- Export -> data/sql_queries_results/segments_distribution.csv

SELECT
    segment,
    COUNT(*)                                              AS segment_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)    AS segment_percentage
FROM v_customer_segments
GROUP BY segment
ORDER BY segment_count DESC, segment;


-- ── 4.2 SEGMENT PROFILES ─────────────────────────────────────────────
-- One row per segment: who they are, how they behave, how much profit
-- they bring. Profit = amount_paid - cogs_per_sale (as in Power BI).
-- NOTE: completion and engagement are part of the segment DEFINITIONS, so
-- differences in those columns are by construction. The informative
-- columns are the ones NOT used by the rules: rating, profit, purchases,
-- login activity of the non-silent segments.
-- avg_days_between_purchases = (last - first purchase) / (purchases - 1),
-- for customers with at least two purchases.

WITH customer_profit AS (
    SELECT p.customer_id,
           SUM(p.amount_paid - c.cogs_per_sale)::numeric AS profit
    FROM purchases p
    INNER JOIN courses c USING (course_id)
    GROUP BY p.customer_id
)
SELECT
    s.segment,
    COUNT(*)                                                         AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)               AS customers_pct,
    ROUND(AVG(s.avg_completion_rate), 2)                             AS avg_completion_rate,
    ROUND(AVG(s.avg_rating), 2)                                      AS avg_rating,
    ROUND(AVG(s.total_purchases), 1)                                 AS avg_purchases,
    ROUND(AVG((s.last_purchase_date - s.first_purchase_date)::numeric
              / NULLIF(s.total_purchases - 1, 0)))                   AS avg_days_between_purchases,
    ROUND(AVG(s.days_since_last_purchase))                           AS avg_days_since_last_purchase,
    ROUND(AVG(s.days_since_first_purchase))                          AS avg_days_since_first_purchase,
    ROUND(AVG(s.days_since_last_login))                              AS avg_days_since_last_login,
    ROUND(AVG(s.engagement_ratio), 2)                                AS avg_engagement_ratio,
    ROUND(AVG(s.sessions_last_90d), 1)                               AS avg_sessions_last_90d,
    ROUND(AVG(s.sessions_prev_90d), 1)                               AS avg_sessions_prev_90d,
    ROUND(100.0 * COUNT(*) FILTER (WHERE s.days_since_last_login <= 30) / COUNT(*)) AS pct_logged_in_last_30d,
    ROUND(SUM(cp.profit))                                            AS total_profit,
    ROUND(100.0 * SUM(cp.profit) / SUM(SUM(cp.profit)) OVER (), 1)   AS profit_share_pct,
    ROUND(AVG(cp.profit))                                            AS avg_profit_per_customer
FROM v_customer_segments s
INNER JOIN customer_profit cp USING (customer_id)
GROUP BY s.segment
ORDER BY customers DESC, s.segment;


-- ── 4.3 WHY CUSTOMERS ARE "AT RISK" ──────────────────────────────────
-- (a) Which rule labelled them (the first matching signal wins).

SELECT
    segment_reason,
    COUNT(*)                                              AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)    AS pct_of_segment
FROM v_customer_segments
WHERE segment = 'At Risk'
GROUP BY segment_reason
ORDER BY customers DESC;

-- (b) How many At Risk customers show each signal (signals overlap, so the
--     columns do not add up to the segment size).

SELECT
    COUNT(*)                                                                         AS at_risk_customers,
    COUNT(*) FILTER (WHERE sessions_prev_90d >= 3
                       AND sessions_last_90d <= 0.5 * sessions_prev_90d)             AS logins_down_50pct,
    COUNT(*) FILTER (WHERE sessions_prev_90d >= 3
                       AND minutes_last_90d  <= 0.5 * minutes_prev_90d)              AS login_time_down_50pct,
    COUNT(*) FILTER (WHERE days_since_last_login > 30)                               AS no_login_30d
FROM v_customer_segments
WHERE segment = 'At Risk';


-- ── 4.4 WHY CUSTOMERS ARE IN "OTHER" ─────────────────────────────────
-- (a) The reason is stored per customer.

SELECT
    segment_reason,
    COUNT(*)                                              AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)    AS pct_of_segment
FROM v_customer_segments
WHERE segment = 'Other'
GROUP BY segment_reason
ORDER BY customers DESC;

-- (b) Where they sit: age of the last purchase and login status.

SELECT
    CASE WHEN days_since_last_purchase <= 30  THEN '1: purchase <=30 days ago'
         WHEN days_since_last_purchase <= 90  THEN '2: purchase 31-90 days ago'
         WHEN days_since_last_purchase <= 180 THEN '3: purchase 91-180 days ago'
         ELSE                                      '4: purchase >180 days ago' END   AS last_purchase,
    COUNT(*)                                                                         AS customers,
    COUNT(*) FILTER (WHERE days_since_last_login <= 90)                              AS logged_in_last_90d,
    ROUND(AVG(avg_completion_rate), 2)                                               AS avg_completion_rate
FROM v_customer_segments
WHERE segment = 'Other'
GROUP BY 1
ORDER BY 1;


-- ── 4.5 HOW SENSITIVE IS "AT RISK" TO ITS THRESHOLDS? ────────────────
-- 03 uses: logins / login time <= 50% of the previous 90 days, or no login
-- for more than 30 days. This grid counts the customers who would be flagged
-- under other choices (rows = decline threshold, columns = days of silence).
-- Population: repeat buyers still in play, i.e. customers currently "At Risk"
-- or "Loyal". The chosen setting is 0.50 / 30 days. The segment stays small
-- (4-8% of customers) under every setting tested.

WITH base AS (
    SELECT
        t.th,
        COALESCE(s.days_since_last_login, 9999) AS days_since_last_login,
        (s.sessions_prev_90d >= 3
         AND (s.sessions_last_90d <= t.th * s.sessions_prev_90d
           OR s.minutes_last_90d  <= t.th * s.minutes_prev_90d)) AS fading
    FROM v_customer_segments s
    CROSS JOIN (VALUES (0.40), (0.50), (0.60), (0.75)) AS t(th)
    WHERE s.segment IN ('At Risk', 'Loyal')
)
SELECT
    th                                                          AS decline_threshold,
    COUNT(*) FILTER (WHERE fading OR days_since_last_login > 21) AS silent_over_21_days,
    COUNT(*) FILTER (WHERE fading OR days_since_last_login > 30) AS silent_over_30_days,
    COUNT(*) FILTER (WHERE fading OR days_since_last_login > 45) AS silent_over_45_days,
    COUNT(*) FILTER (WHERE fading OR days_since_last_login > 60) AS silent_over_60_days
FROM base
GROUP BY th
ORDER BY th;


-- ── 4.6 INTEGRITY CHECKS (every row must show violations = 0) ────────

SELECT check_name, violations,
       CASE WHEN violations = 0 THEN 'OK' ELSE 'CHECK' END AS status
FROM (
    SELECT 'customers missing from the segmentation' AS check_name,
           (SELECT COUNT(*) FROM customers)
         - (SELECT COUNT(DISTINCT customer_id) FROM v_customer_segments) AS violations
    UNION ALL
    SELECT 'duplicated customers in the segmentation',
           COUNT(*) - COUNT(DISTINCT customer_id) FROM v_customer_segments
    UNION ALL
    SELECT 'customers with an empty segment',
           COUNT(*) FROM v_customer_segments WHERE segment IS NULL OR segment = ''
    UNION ALL
    SELECT 'segment name outside the seven expected',
           COUNT(*) FROM v_customer_segments
           WHERE segment NOT IN ('Champion','Loyal','Collector','At Risk','New','Hibernating','Other')
    UNION ALL
    SELECT 'customers in Other that matched no rule',
           COUNT(*) FROM v_customer_segments
           WHERE segment_reason LIKE 'no rule matched%'
) AS checks;
