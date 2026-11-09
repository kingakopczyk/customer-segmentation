-- =====================================================================
-- 03_SEGMENTATION.SQL  |  Behavioural enrichment and segment assignment
-- =====================================================================
-- RUN     : the whole file at once (Ctrl+A, Ctrl+E, E). It creates two views:
--             v_behavior           one row per customer: completion, rating,
--                                  engagement and login activity
--             v_customer_segments  the final segmentation (one row per customer)
-- REQUIRES: 00_schema.sql (tables + v_params), 02_rfm_scoring.sql (v_rfm).
-- EXPORT  : see the end of the file -> data/sql_queries_results/segmentation.csv
--
-- Every later query (04, the CSV export, Power BI, Excel) reads from the
-- single view v_customer_segments, so the rules below exist in ONE place only.
--
-- ---------------------------------------------------------------------
-- SEGMENT RULES  (evaluated top to bottom, the FIRST matching rule wins)
-- ---------------------------------------------------------------------
--  #  Segment      Rule
--  1  New          first purchase <= 90 days ago AND at most 2 purchases (f_score <= 2)
--  2  Hibernating  no purchase for > 180 days (r_score <= 2) AND no login for > 90 days
--  3  Champion     last purchase <= 90 days ago (r_score >= 4), 5+ purchases (f_score >= 4),
--                  avg completion >= 0.75 AND engagement ratio >= 1.0
--  4  Collector    3+ purchases (f_score >= 3) AND avg completion < 0.55
--  5  At Risk      3+ purchases (f_score >= 3) AND at least one fading-usage signal:
--                    a) logins in the last 90 days <= 50% of the previous 90 days, or
--                    b) login time in the last 90 days <= 50% of the previous 90 days
--                       (a and b need >= 3 sessions in the previous 90 days), or
--                    c) no login for more than 30 days
--                  (completion >= 0.55 is implied: lower-completion buyers are Collectors)
--  6  Loyal        3+ purchases (f_score >= 3), avg completion >= 0.55,
--                  last purchase <= 180 days ago (r_score >= 3)
--  7  Other        everything else. With these rules that is: customers with exactly
--                  two purchases whose first purchase is older than 90 days and who are
--                  not (yet) hibernating - too little purchase history for a pattern.
--
-- Design notes
--   * "Repeat buyer" = 3+ purchases. Frequency uses fixed thresholds (see 02).
--   * Recent window = the last 90 days before the snapshot date, previous
--     window = the 90 days before that. The snapshot date lives in v_params.
--   * Hibernating means silent on BOTH fronts (no purchase and no login),
--     so learners who still log in are never labelled "forgotten".
--   * At Risk is driven by fading LOGIN activity (count, time, silence),
--     not by purchase recency alone. Rating trends are exposed as columns
--     (early/late_avg_rating) but deliberately not used as a trigger: with
--     only a few ratings per customer they are mostly noise.
--   * The CASE returns "segment|reason"; both columns are split from it,
--     so every customer carries a human-readable explanation
--     (segment_reason) and the rules still live in one place.
--   * The thresholds (50%, 30 days, 90-day windows) are judgement calls:
--     04_segments_distribution.sql shows how many customers each signal flags.
-- =====================================================================

DROP VIEW IF EXISTS v_customer_segments;
DROP VIEW IF EXISTS v_behavior;


-- ── 3.1 VIEW v_behavior : BEHAVIOURAL FEATURES PER CUSTOMER ──────────

CREATE VIEW v_behavior AS
WITH
-- completion rate and rating over ALL of the customer's assessments
completion AS (
    SELECT
        customer_id,
        ROUND(AVG(completion_rate)::numeric, 2)           AS avg_completion_rate,
        ROUND(AVG(rating)::numeric, 2)                    AS avg_rating   -- AVG ignores unrated courses
    FROM assessments
    GROUP BY customer_id
),

-- average session length per course: the benchmark for engagement
course_avg AS (
    SELECT course_id, AVG(login_duration) AS course_avg_duration
    FROM logins
    GROUP BY course_id
),

-- login volume, engagement and activity in the last / previous 90 days
sessions AS (
    SELECT
        l.customer_id,
        COUNT(*)                                          AS total_sessions,
        -- engagement ratio: session length vs the average for that same
        -- course (> 1.0 = longer than the course average)
        ROUND(AVG(l.login_duration::numeric
                  / NULLIF(ca.course_avg_duration, 0))::numeric, 2)       AS engagement_ratio,
        MAX(l.login_date)                                 AS last_login_date,
        COUNT(*) FILTER (WHERE l.login_date >  p.snapshot_date - 90)      AS sessions_last_90d,
        COUNT(*) FILTER (WHERE l.login_date >  p.snapshot_date - 180
                           AND l.login_date <= p.snapshot_date - 90)      AS sessions_prev_90d,
        COALESCE(SUM(l.login_duration) FILTER (WHERE l.login_date >  p.snapshot_date - 90), 0)
                                                          AS minutes_last_90d,
        COALESCE(SUM(l.login_duration) FILTER (WHERE l.login_date >  p.snapshot_date - 180
                                                 AND l.login_date <= p.snapshot_date - 90), 0)
                                                          AS minutes_prev_90d
    FROM logins l
    INNER JOIN course_avg ca USING (course_id)
    CROSS JOIN v_params p
    GROUP BY l.customer_id
),

-- early vs late session length (first vs second half of a customer's sessions).
-- Descriptive only: not used by the rules. A customer with a single session
-- has NULL early_avg_duration. login_id breaks same-day ties deterministically.
session_trend AS (
    SELECT
        customer_id,
        ROUND(AVG(login_duration) FILTER (WHERE session_rank <= FLOOR(total_sessions / 2.0))::numeric, 2)
                                                          AS early_avg_duration,
        ROUND(AVG(login_duration) FILTER (WHERE session_rank >  FLOOR(total_sessions / 2.0))::numeric, 2)
                                                          AS late_avg_duration
    FROM (
        SELECT
            customer_id,
            login_duration,
            ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY login_date, login_id) AS session_rank,
            COUNT(*)     OVER (PARTITION BY customer_id)                               AS total_sessions
        FROM logins
    ) AS ranked
    GROUP BY customer_id
),

-- early vs late rating (ordered by purchase). Descriptive only: not used by the rules.
rating_trend AS (
    SELECT
        a.customer_id,
        ROUND(AVG(a.rating) FILTER (WHERE p.purchase_rank <= FLOOR(p.total_purchases / 2.0))::numeric, 2)
                                                          AS early_avg_rating,
        ROUND(AVG(a.rating) FILTER (WHERE p.purchase_rank >  FLOOR(p.total_purchases / 2.0))::numeric, 2)
                                                          AS late_avg_rating
    FROM assessments a
    INNER JOIN (
        SELECT
            customer_id,
            course_id,
            ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY purchase_date, purchase_id) AS purchase_rank,
            COUNT(*)     OVER (PARTITION BY customer_id)                                     AS total_purchases
        FROM purchases
    ) AS p USING (customer_id, course_id)
    GROUP BY a.customer_id
)

SELECT
    c.customer_id,
    c.avg_completion_rate,
    c.avg_rating,
    s.total_sessions,
    s.engagement_ratio,
    s.last_login_date,
    s.sessions_last_90d,
    s.sessions_prev_90d,
    s.minutes_last_90d,
    s.minutes_prev_90d,
    st.early_avg_duration,
    st.late_avg_duration,
    rt.early_avg_rating,
    rt.late_avg_rating
FROM completion c
LEFT JOIN sessions       s  USING (customer_id)
LEFT JOIN session_trend  st USING (customer_id)
LEFT JOIN rating_trend   rt USING (customer_id);


-- ── 3.2 VIEW v_customer_segments : FINAL SEGMENTATION ────────────────

CREATE VIEW v_customer_segments AS
WITH joined AS (
    SELECT
        r.customer_id,
        r.last_purchase_date,
        r.days_since_last_purchase,
        r.r_score,
        r.total_purchases,
        r.f_score,
        r.total_spent,
        r.m_score,
        r.rfm_score,
        b.avg_completion_rate,
        b.avg_rating,
        b.total_sessions,
        b.engagement_ratio,
        b.early_avg_duration,
        b.late_avg_duration,
        b.early_avg_rating,
        b.late_avg_rating,
        r.first_purchase_date,
        r.days_since_first_purchase,
        b.last_login_date,
        (p.snapshot_date - b.last_login_date)              AS days_since_last_login,
        COALESCE(b.sessions_last_90d, 0)                   AS sessions_last_90d,
        COALESCE(b.sessions_prev_90d, 0)                   AS sessions_prev_90d,
        COALESCE(b.minutes_last_90d, 0)                    AS minutes_last_90d,
        COALESCE(b.minutes_prev_90d, 0)                    AS minutes_prev_90d
    FROM v_rfm r
    LEFT JOIN v_behavior b USING (customer_id)
    CROSS JOIN v_params p
),
assigned AS (
    SELECT
        j.*,
        CASE
            -- 1. New: first purchase within the last 90 days, at most two purchases
            WHEN days_since_first_purchase <= 90
             AND f_score <= 2
                THEN 'New|first purchase <=90 days ago, at most 2 purchases'

            -- 2. Hibernating: silent on both fronts (a customer who never logged in counts as silent)
            WHEN r_score <= 2
             AND COALESCE(days_since_last_login, 9999) > 90
                THEN 'Hibernating|no purchase for >180 days and no login for >90 days'

            -- 3. Champion: recent, frequent, completes courses, long engaged sessions
            WHEN r_score >= 4
             AND f_score >= 4
             AND avg_completion_rate >= 0.75
             AND engagement_ratio   >= 1.0
                THEN 'Champion|purchase <=90 days ago, 5+ purchases, completion >=75%, engagement >=1.0'

            -- 4. Collector: buys repeatedly but rarely finishes
            WHEN f_score >= 3
             AND avg_completion_rate < 0.55
                THEN 'Collector|3+ purchases but completion <55%'

            -- 5. At Risk: repeat buyer whose login activity is fading
            --    (the first matching signal labels the reason)
            WHEN f_score >= 3
             AND sessions_prev_90d >= 3
             AND sessions_last_90d <= 0.5 * sessions_prev_90d
                THEN 'At Risk|3+ purchases, logins down >=50% vs previous 90 days'
            WHEN f_score >= 3
             AND sessions_prev_90d >= 3
             AND minutes_last_90d <= 0.5 * minutes_prev_90d
                THEN 'At Risk|3+ purchases, login time down >=50% vs previous 90 days'
            WHEN f_score >= 3
             AND COALESCE(days_since_last_login, 9999) > 30
                THEN 'At Risk|3+ purchases, no login for >30 days'

            -- 6. Loyal: steady repeat buyer with solid completion, still buying
            WHEN f_score >= 3
             AND avg_completion_rate >= 0.55
             AND r_score >= 3
                THEN 'Loyal|3+ purchases, completion >=55%, purchase <=180 days ago'

            -- 7. Other: residual, with the reason spelled out
            WHEN f_score = 2
                THEN 'Other|exactly two purchases (below the 3-purchase threshold), first purchase >90 days ago, not yet hibernating'
            WHEN f_score = 1
                THEN 'Other|single purchase older than 90 days, not yet hibernating'
            ELSE 'Other|no rule matched (unexpected - investigate)'
        END AS segment_rule
    FROM joined j
)
SELECT
    customer_id,
    last_purchase_date,
    days_since_last_purchase,
    r_score,
    total_purchases,
    f_score,
    total_spent,
    m_score,
    rfm_score,
    avg_completion_rate,
    avg_rating,
    total_sessions,
    engagement_ratio,
    early_avg_duration,
    late_avg_duration,
    early_avg_rating,
    late_avg_rating,
    SPLIT_PART(segment_rule, '|', 1)    AS segment,
    SPLIT_PART(segment_rule, '|', 2)    AS segment_reason,
    first_purchase_date,
    days_since_first_purchase,
    last_login_date,
    days_since_last_login,
    sessions_last_90d,
    sessions_prev_90d,
    minutes_last_90d,
    minutes_prev_90d
FROM assigned;


-- ── 3.3 QUICK CHECK ──────────────────────────────────────────────────

SELECT segment, COUNT(*) AS customers
FROM v_customer_segments
GROUP BY segment
ORDER BY customers DESC, segment;


-- ── 3.4 EXPORT FOR POWER BI / EXCEL ──────────────────────────────────
-- Export the result grid (CSV, with header) to
-- data/sql_queries_results/segmentation.csv
-- psql users can wrap the query in
-- \copy (...) TO '<file>' CSV HEADER.

SELECT *
FROM v_customer_segments
ORDER BY customer_id;
