-- =====================================================================
-- 05_EXTRA_ANALYSIS.SQL  |  Four additional analyses on the same database
-- =====================================================================
-- PURPOSE : four stand-alone business questions that practise window
--           functions and cohort logic. They do not feed Power BI, Excel
--           or the CSV exports, so the segmentation (00-04) is unaffected.
-- RUN     : query by query - select a query and press Ctrl+E, E.
-- REQUIRES: 00_schema.sql with the data loaded (tables + view v_params).
--           Query 5.2 also needs 03_segmentation.sql (v_customer_segments).
-- ENGINE  : PostgreSQL 14+ (tested on 16).
-- DATA    : synthetic (1,000 customers, Jan 2022 - Dec 2024), so the
--           findings below describe this dataset, not a real platform.
--
--   5.1  Month-over-month revenue ........... LAG, DATE_TRUNC, NULLIF
--   5.2  Top 3 customers per segment ........ ROW_NUMBER vs RANK
--   5.3  Cumulative profit, moving average .. window frames
--   5.4  Cohort retention (6 months) ........ CTEs, date arithmetic, FILTER
--
-- Every block has: business question, how it works, result, notes.
-- The RESULT lines come from running this file on the full dataset; figures
-- from ad-hoc checks are marked "separate check".
-- =====================================================================


-- ── 5.1 MONTH-OVER-MONTH REVENUE ─────────────────────────────────────
-- Business question : Is revenue growing or shrinking from month to month?
-- Task              : Calculate monthly revenue and its change versus the
--                     previous month, both as an absolute value and as a
--                     percentage. Handle the first month, which has no
--                     previous value.
-- Techniques        : LAG, DATE_TRUNC, NULLIF, COALESCE
--
-- HOW IT WORKS
--   * The inner query adds up amount_paid per calendar month. LAG() copies
--     the previous month's total onto the current row. LAG can wrap SUM()
--     because window functions are evaluated after GROUP BY.
--   * The outer query only does arithmetic and formatting, so the LAG logic
--     is written once.
--   * First month: LAG returns NULL, so the absolute change stays NULL and
--     the percentage shows 'n/a' (COALESCE). NULLIF(x, 0) turns a zero
--     denominator into NULL instead of a division-by-zero error.
--
-- RESULT (36 months, Jan 2022 - Dec 2024)
--   * Revenue rose in 24 months and fell in 11; the first month has nothing
--     to compare with.
--   * The largest fall is the last month: Dec 2024, -$8,973 (-32%), after the
--     record Nov 2024 ($27,890). Year over year Dec is still +61% (Dec 2023:
--     $11,747), so this is a dip inside a growth phase. One month is not a
--     trend: 5.3 shows it on a smoothed line.
--   * The second-largest fall is Oct 2024: -$2,551 (-10%).
--   * Early-2022 percentages are not meaningful: Feb +81% and Mar +541% sit
--     on a base of $98-$177 a month. Read the absolute change there.
--
-- NOTES
--   * LAG looks at the previous ROW, not the previous calendar month. The two
--     are the same here because all 36 months have sales. A month without
--     sales would be missing and LAG would skip over the gap; joining to a
--     calendar from generate_series() would make it robust.
--   * revenue_pct_change is TEXT because of 'n/a'. For a chart or Power BI,
--     drop the COALESCE and keep NULL so the column stays numeric.
--   * Month-over-month ignores seasonality; with three years of data a
--     year-over-year view exists only for 2023 and 2024.

SELECT
    TO_CHAR(purchase_month, 'YYYY-MM') AS purchase_month,
    revenue,
    previous_month_revenue,
    revenue - previous_month_revenue AS revenue_absolute_change,  -- NULL in month 1
    COALESCE(ROUND(100.0 * (revenue - previous_month_revenue)
        / NULLIF(previous_month_revenue, 0), 0)::TEXT, 'n/a') AS revenue_pct_change
FROM (
    SELECT
        DATE_TRUNC('month', purchase_date)::DATE AS purchase_month,
        SUM(amount_paid) AS revenue,
        LAG(SUM(amount_paid)) OVER (
            ORDER BY DATE_TRUNC('month', purchase_date)::DATE
        ) AS previous_month_revenue
    FROM purchases
    GROUP BY purchase_month
) AS monthly_revenue
ORDER BY purchase_month;  -- sorts on the 'YYYY-MM' text, which is chronological


-- ── 5.2 TOP CUSTOMERS PER SEGMENT ────────────────────────────────────
-- Business question : Who are the most valuable customers inside each
--                     segment?
-- Task              : Return the top 3 customers by total amount paid in
--                     each segment. Show how the result changes when you use
--                     ROW_NUMBER versus RANK if several customers have the
--                     same total.
-- Techniques        : ROW_NUMBER, RANK, PARTITION BY, CTE
--
-- HOW IT WORKS
--   * PARTITION BY segment restarts the numbering in every segment;
--     ORDER BY total_spent DESC puts the biggest spender first.
--   * ROW_NUMBER never repeats a number: two customers with the same total
--     get 1 and 2. RANK gives them the same rank and skips the next one:
--     1, 1, 3.
--   * The CTE is needed because a window function cannot be used in WHERE:
--     it is computed first and filtered in the outer query.
--   * if_changing = 'True' marks the rows where the two numberings differ,
--     i.e. customers who are tied with someone listed above them.
--   * The filter uses RANK, so a tie at the border keeps every tied customer
--     and a segment can return more than 3 rows. ROW_NUMBER <= 3 would give
--     exactly 3 rows but drop a customer who spent exactly as much as one
--     that is kept - decided only by the order of customer_id.
--   * ROW_NUMBER gets customer_id as a tie-breaker, so its numbering is the
--     same on every run (without it, the order among tied customers is
--     arbitrary). RANK has none on purpose: it has to see the ties.
--   * The source is the view v_customer_segments (always the current
--     segmentation rules), not an exported table.
--
-- RESULT (23 rows, 7 segments)
--   * Five segments return 3 rows. Collector and Hibernating return 4,
--     because two customers share 3rd place:
--       Collector   - U0363 and U0460, both $641
--       Hibernating - U0428 and U0709, both $345
--     ROW_NUMBER <= 3 would have dropped U0460 and U0709.
--   * More ties: Champion $858 (U0495, U0946), Collector $660 (U0364, U0941)
--     and Loyal $798 (U0402, U0452) share 1st place; Other $188 (U0342,
--     U0348) shares 2nd.
--   * Highest single spender per segment: Champion $858, Loyal $798,
--     Collector $660, At Risk $572, Hibernating $415, Other $198, New $178.
--
-- NOTES
--   * Ties are not an edge case here. total_spent is a sum of at most 15
--     fixed prices ($19-$99; a course is bought once and always paid at list
--     price), so identical totals are common: Other has 40 customers but
--     only 14 different totals.
--   * if_changing is a text flag ('True'/'False'). A real boolean,
--     customer_row_nr <> customer_rank, is easier to filter and count.

WITH whole_ranking_cte AS (
    SELECT
        customer_id,
        total_spent,
        segment,
        ROW_NUMBER() OVER (
            PARTITION BY segment
            ORDER BY total_spent DESC, customer_id   -- customer_id breaks ties
        ) AS customer_row_nr,
        RANK() OVER (
            PARTITION BY segment
            ORDER BY total_spent DESC                -- no tie-breaker: ties wanted
        ) AS customer_rank
    FROM v_customer_segments
)
SELECT
    customer_id,
    total_spent,
    segment,
    customer_row_nr,
    customer_rank,
    CASE WHEN customer_row_nr <> customer_rank THEN 'True'
         ELSE 'False'
    END AS if_changing
FROM whole_ranking_cte
WHERE customer_rank <= 3
ORDER BY segment, customer_rank, customer_id;


-- ── 5.3 CUMULATIVE PROFIT AND 3-MONTH MOVING AVERAGE ─────────────────
-- Business question : How is profit building up over time, and what is the
--                     underlying trend?
-- Task              : For each month, calculate profit (revenue minus cost of
--                     sales), the cumulative profit since the start, and a
--                     3-month moving average.
-- Techniques        : window frames (ROWS BETWEEN UNBOUNDED PRECEDING AND
--                     CURRENT ROW, ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
--
-- HOW IT WORKS
--   * The CTE reduces the data to one row per month. profit_per_sale is
--     course_price - cogs_per_sale (01, check 18) and every purchase is paid
--     at list price (01, check 17), so the sum equals amount_paid minus
--     cogs_per_sale: the profit definition used in 4.2 and in Power BI.
--   * Cumulative profit: the frame UNBOUNDED PRECEDING .. CURRENT ROW is a
--     running total from the first month to the current one.
--   * Moving average: the frame 2 PRECEDING .. CURRENT ROW is the current
--     month and the two before it. ROWS counts rows, not calendar time; that
--     is right here because every month has a row.
--
-- CHECK
--   * The last row (Dec 2024) shows a cumulative profit of $177,753, the
--     total profit on the Power BI dashboard.
--
-- RESULT (36 months)
--   * 2024 produced $120,064 of the $177,753 total profit (67.5%); the
--     cumulative profit was $57,689 at the end of 2023.
--   * Monthly profit peaked in Nov 2024 ($14,763) and fell to $10,043 in
--     Dec 2024 (-32% on Nov, +61% on Dec 2023: $6,221).
--   * The 3-month average fell in only 2 of the 35 months where it can be
--     compared: Oct 2022 (-$27) and Dec 2024 (-$1,065, from $13,268 to
--     $12,203, back to the level of Sep 2024). Dec 2024 is the only notable
--     break in a rising series; one month cannot say if it is a turning point.
--
-- NOTES
--   * The first two moving-average values (Jan and Feb 2022: $51, $72) are
--     averages of only 1 and 2 months. To show full 3-month windows only,
--     return NULL while COUNT(*) OVER (same frame) is below 3.
--   * month is TEXT ('YYYY-MM'). It sorts correctly, but a DATE
--     (DATE_TRUNC('month', ...)::DATE) is safer for date arithmetic and is
--     what Power BI would expect.
--   * LEFT JOIN courses returns the same rows as INNER JOIN here: course_id
--     is NOT NULL and a foreign key, so every purchase has a course.

WITH monthly_profit_cte AS (
    SELECT
        TO_CHAR(DATE_TRUNC('Month', purchases.purchase_date), 'YYYY-MM') AS month,
        SUM(courses.profit_per_sale) AS profit
    FROM purchases
    LEFT JOIN courses
    USING (course_id)
    GROUP BY TO_CHAR(DATE_TRUNC('Month', purchases.purchase_date), 'YYYY-MM')
)
SELECT
    month,
    ROUND(profit, 0) AS profit,
    ROUND(SUM(profit) OVER (
        ORDER BY month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 0) AS cumulative_profit,
    ROUND(AVG(profit) OVER (
        ORDER BY month
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0) AS moving_average_profit
FROM monthly_profit_cte
ORDER BY month;


-- ── 5.4 COHORT RETENTION ─────────────────────────────────────────────
-- Business question : Do customers keep learning after they buy their first
--                     course?
-- Task              : Group customers into cohorts by the month of their
--                     first purchase. For each cohort, calculate the share of
--                     customers with at least one login session in each of
--                     the following 6 months.
-- Techniques        : CTEs, MIN per customer, date arithmetic, conditional
--                     aggregation (FILTER)
--
-- HOW IT WORKS
--   1. first_purchase: one row per customer with the month of the first
--      purchase. That month is the customer's cohort.
--   2. activity: for every login, month_offset = calendar months between the
--      cohort month and the login month (0 = the cohort month itself, 1 =
--      the next month, ...). Year * 12 + month arithmetic is used because
--      subtracting dates gives days, and 30 days is not one month.
--   3. Final SELECT: COUNT(DISTINCT customer) FILTER (WHERE month_offset = k)
--      is the number of customers active in month k; dividing by the cohort
--      size gives the percentage. FILTER is PostgreSQL's conditional
--      aggregation. COUNT(DISTINCT) is needed because the join returns one
--      row per customer and active month.
--   4. HAVING keeps only cohorts with a complete 6-month follow-up: the last
--      cohort is the month that lies six months before the last login in the
--      data (Jun 2024). A younger cohort would show 0% for months that have
--      not happened yet, which looks like churn but is only missing data.
--
-- DEFINITION
--   "Retained in month k" = at least one login in calendar month k after the
--   cohort month, in ANY of the customer's courses. It is not a repeat
--   purchase, and it is not cumulative: a customer can be absent in month 3
--   and back in month 4. Month 0 (the purchase month) is left out.
--
-- RESULT (30 cohorts, Jan 2022 - Jun 2024)
--   * The first two cohorts have 2 and 3 customers, so one customer moves a
--     percentage by 50 or 33 points: ignore them. From Mar 2022 on, cohorts
--     have 11-48 customers.
--   * 2022-23 cohorts, all pooled (650 customers): 76-84% are active in each
--     of months 1-5 and 70% in month 6. Month 6 is below month 5 in 20 of the
--     22 cohorts from Mar 2022 to Dec 2023, by 14 points on average.
--   * The 2024 cohorts (Jan-Jun) do not show that drop: month 6 is 87-100%.
--     Weighted by cohort size, month-6 activity is 66% for the 2022 cohorts,
--     72% for 2023 and 93% for Jan-Jun 2024.
--
-- NOTES
--   * Read the curve with the data in mind (separate check, not part of this
--     file): every login falls 0-180 days after the purchase of its course
--     (99th percentile: 177), so without a new purchase activity ends around
--     month 6. That is why month 6 drops, and why the 51-56% active in
--     months 7-12 can only come from later purchases.
--   * The higher 2024 curve is partly repeat buying, not stickier learners
--     (same separate check): 168 of 188 customers (89%) in the Jan-Jun 2024
--     cohorts bought again in months 1-6, against 58% in 2022 and 71% in
--     2023, and repeat buyers are active in month 6 far more often (82-98%)
--     than one-time buyers (38-50%). Logins are counted across ALL of a
--     customer's courses.
--   * HAVING works, but its condition contains no aggregate, so WHERE is the
--     usual place: it filters before grouping. The result is the same.
--   * The cut-off uses MAX(login_date) = 31 Dec 2024. It could read
--     v_params.snapshot_date like 02-04; the result is the same here.
--   * DISTINCT in activity is not needed for correct percentages (the
--     COUNT(DISTINCT) below already protects them); it shrinks the join from
--     51,609 logins to 10,622 customer-months. activity also keeps offsets
--     0 and 7+, which the final query never reads.
--   * Small cohorts are noisy: for a summary, pool them by quarter or half
--     year instead of reading 30 rows.

WITH first_purchase AS (
    SELECT
        customer_id,
        DATE_TRUNC('MONTH', MIN(purchase_date))::DATE AS cohort_month
    FROM purchases
    GROUP BY customer_id
),
activity AS (
    SELECT DISTINCT
        f.customer_id,
        (DATE_PART('YEAR', l.login_date) - DATE_PART('YEAR', f.cohort_month)) * 12
        + DATE_PART('MONTH', l.login_date) - DATE_PART('MONTH', f.cohort_month)
            AS month_offset
    FROM first_purchase f
    INNER JOIN logins l
    USING (customer_id)
)
SELECT
    TO_CHAR(f.cohort_month, 'YYYY-MM') AS cohort,
    COUNT(DISTINCT f.customer_id) AS size,
    ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_offset = 1)
        / COUNT(DISTINCT f.customer_id), 0) AS mth_1_pct,
    ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_offset = 2)
        / COUNT(DISTINCT f.customer_id), 0) AS mth_2_pct,
    ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_offset = 3)
        / COUNT(DISTINCT f.customer_id), 0) AS mth_3_pct,
    ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_offset = 4)
        / COUNT(DISTINCT f.customer_id), 0) AS mth_4_pct,
    ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_offset = 5)
        / COUNT(DISTINCT f.customer_id), 0) AS mth_5_pct,
    ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_offset = 6)
        / COUNT(DISTINCT f.customer_id), 0) AS mth_6_pct
FROM first_purchase f
LEFT JOIN activity a
USING (customer_id)
GROUP BY f.cohort_month
HAVING f.cohort_month <= (   -- complete 6-month follow-up only
    SELECT DATE_TRUNC('MONTH', MAX(login_date)) - INTERVAL '6 months' FROM logins)
ORDER BY cohort;
