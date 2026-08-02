-- ============================================================
-- 03_segmentation.sql
-- Behavioral Enrichment and Segment Assignment
-- Run the full query at once: Ctrl+A to select all, Ctrl+E, E
-- ============================================================

WITH

-- ── 1. RECENCY ───────────────────────────────────────────────
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

-- ── 2. FREQUENCY ─────────────────────────────────────────────
frequency AS (
    SELECT
        customer_id,
        COUNT(purchase_id)                                    AS total_purchases,
        NTILE(5) OVER (ORDER BY COUNT(purchase_id) ASC)       AS f_score
    FROM purchases
    GROUP BY customer_id
),

-- ── 3. MONETARY ──────────────────────────────────────────────
monetary AS (
    SELECT
        customer_id,
        ROUND(SUM(amount_paid)::numeric, 2)                   AS total_spent,
        NTILE(5) OVER (ORDER BY SUM(amount_paid) ASC)         AS m_score
    FROM purchases
    GROUP BY customer_id
),

-- ── 4. COMPLETION RATE AND RATING ────────────────────────────
behavior AS (
    SELECT
        customer_id,
        ROUND(AVG(completion_rate)::numeric, 2)               AS avg_completion_rate,
        ROUND(AVG(rating)::numeric, 2)                        AS avg_rating
    FROM assessments
    GROUP BY customer_id
),

-- ── 5. SESSION ENGAGEMENT RATIO ──────────────────────────────
-- Compares each customer's session duration to the average for
-- that specific course. Ratio > 1.0 = above-average engagement.
session_behavior AS (
    SELECT
        l.customer_id,
        COUNT(l.login_id)                                     AS total_sessions,
        ROUND(
            AVG(
                l.login_duration::numeric /
                NULLIF(course_avg.course_avg_duration, 0)
            )::numeric, 2
        )                                                     AS engagement_ratio
    FROM logins l
    INNER JOIN (
        SELECT
            course_id,
            AVG(login_duration)                               AS course_avg_duration
        FROM logins
        GROUP BY course_id
    ) AS course_avg USING (course_id)
    GROUP BY l.customer_id
),

-- ── 6. SESSION DURATION TREND ────────────────────────────────
-- Sessions split into early and late halves per customer.
-- A significant drop in late sessions signals declining engagement.
-- Customers with only one session will have NULL in late_avg_duration.
session_trend AS (
    SELECT
        customer_id,
        AVG(CASE WHEN session_rank <= total_sessions / 2
                 THEN login_duration END)                     AS early_avg_duration,
        AVG(CASE WHEN session_rank > total_sessions / 2
                 THEN login_duration END)                     AS late_avg_duration
    FROM (
        SELECT
            customer_id,
            login_duration,
            ROW_NUMBER() OVER (
                PARTITION BY customer_id
                ORDER BY login_date ASC)                      AS session_rank,
            COUNT(*) OVER (
                PARTITION BY customer_id)                     AS total_sessions
        FROM logins
    ) AS ranked
    GROUP BY customer_id
),

-- ── 7. RATING TREND ──────────────────────────────────────────
-- Ratings split into early and late halves based on purchase order.
-- A drop in late ratings may indicate growing dissatisfaction.
-- Customers with only one rated course will have NULL in late_avg_rating.
rating_trend AS (
    SELECT
        a.customer_id,
        AVG(CASE WHEN purchase_rank <= total_purchases / 2
                 THEN a.rating END)                           AS early_avg_rating,
        AVG(CASE WHEN purchase_rank > total_purchases / 2
                 THEN a.rating END)                           AS late_avg_rating
    FROM assessments a
    INNER JOIN (
        SELECT
            customer_id,
            course_id,
            ROW_NUMBER() OVER (
                PARTITION BY customer_id
                ORDER BY purchase_date ASC)                   AS purchase_rank,
            COUNT(*) OVER (
                PARTITION BY customer_id)                     AS total_purchases
        FROM purchases
    ) AS p USING (customer_id, course_id)
    WHERE a.rating IS NOT NULL
    GROUP BY a.customer_id
)

-- ── FINAL SELECT WITH SEGMENT ASSIGNMENT ─────────────────────
SELECT
    r.customer_id,
    r.last_purchase_date,
    r.days_since_last_purchase,
    r.r_score,
    f.total_purchases,
    f.f_score,
    m.total_spent,
    m.m_score,
    (r.r_score + f.f_score + m.m_score)                       AS rfm_score,
    b.avg_completion_rate,
    b.avg_rating,
    sb.total_sessions,
    sb.engagement_ratio,
    st.early_avg_duration,
    st.late_avg_duration,
    rt.early_avg_rating,
    rt.late_avg_rating,

    CASE
        -- Champion: recent, frequent, completes courses, engaged in sessions
        WHEN r.r_score >= 4
             AND f.f_score >= 4
             AND b.avg_completion_rate >= 0.75
             AND sb.engagement_ratio >= 1.0                   THEN 'Champion'

        -- Collector: buys frequently but rarely finishes, short sessions
        WHEN f.f_score >= 3
             AND b.avg_completion_rate < 0.55                 THEN 'Collector'

        -- At Risk: previously active, showing at least one warning signal:
        -- long absence, declining session duration, or dropping ratings
        WHEN f.f_score >= 3
             AND (
                 r.r_score <= 2
                 OR (
                     st.late_avg_duration IS NOT NULL
                     AND st.late_avg_duration < st.early_avg_duration * 0.75
                 )
                 OR (
                     rt.late_avg_rating IS NOT NULL
                     AND rt.late_avg_rating < rt.early_avg_rating - 0.5
                 )
             )                                                THEN 'At Risk'

        -- Loyal: regular buyer with solid completion rate
        WHEN r.r_score >= 3
             AND f.f_score >= 3
             AND b.avg_completion_rate >= 0.55                THEN 'Loyal'

        -- New: joined recently, only one or two purchases
        WHEN r.r_score = 5
             AND f.f_score <= 2                               THEN 'New'

        -- Hibernating: all remaining customers
        ELSE 'Hibernating'
    END                                                       AS segment

FROM recency              r
INNER JOIN frequency      f  USING (customer_id)
INNER JOIN monetary       m  USING (customer_id)
LEFT  JOIN behavior       b  USING (customer_id)
LEFT  JOIN session_behavior sb USING (customer_id)
LEFT  JOIN session_trend  st USING (customer_id)
LEFT  JOIN rating_trend   rt USING (customer_id)
ORDER BY rfm_score DESC;