-- 05_reporting_views.sql
-- Step 5: build the views that Tableau reads. A view is a saved SELECT query with a name.
-- One view per dashboard tab (KPI 1 to KPI 5) plus one detail view.
--
-- Every rate below = (discharges with the flag) / (all discharges).
-- CAST(... AS FLOAT) is needed because in SQL Server a whole number divided by a whole number
-- gives a whole number: 627897 / 1474025 = 0, but CAST(627897 AS FLOAT) / 1474025 = 0.426.

USE TEDS_BI;
GO

-- KPI 2: completion by state, with two flags.
-- Built in small steps with a CTE (WITH ... AS): each step is a mini table the next step can use.
CREATE OR ALTER VIEW rpt.vw_kpi2_state_completion AS
WITH state_totals AS (            -- step 1: one row per state with its counts and rates
    SELECT state_key,
           COUNT(*)                                          AS discharges,
           SUM(completed_flag)                               AS completed,
           CAST(SUM(completed_flag) AS FLOAT) / COUNT(*)     AS completion_rate,
           CAST(SUM(dropout_flag) AS FLOAT) / COUNT(*)       AS dropout_rate,
           CAST(SUM(early_dropout_flag) AS FLOAT) / COUNT(*) AS early_dropout_rate,
           CAST(SUM(transfer_flag) AS FLOAT) / COUNT(*)      AS transfer_rate
    FROM dw.fact_discharge
    GROUP BY state_key
),
reason_counts AS (                -- step 2: number of discharges per state and reason
    SELECT state_key, reason_key, COUNT(*) AS reason_count
    FROM dw.fact_discharge
    GROUP BY state_key, reason_key
),
top_reason AS (                   -- step 3: the largest reason count in each state
    SELECT state_key, MAX(reason_count) AS top_reason_count
    FROM reason_counts
    GROUP BY state_key
),
peer AS (                         -- step 4: average and standard deviation of state rates
    SELECT AVG(completion_rate)   AS peer_avg,      --         (states with 1,000+ discharges only)
           STDEV(completion_rate) AS peer_sd
    FROM state_totals
    WHERE discharges >= 1000
),
us_total AS (                     -- step 5: the national completion rate
    SELECT CAST(SUM(completed_flag) AS FLOAT) / COUNT(*) AS national_rate
    FROM dw.fact_discharge
)
SELECT t.state_key,                -- step 6: put it all together
       st.state_name,
       st.state_abbr,
       st.census_region,
       st.census_division,
       t.discharges,
       t.completed,
       t.completion_rate,
       t.dropout_rate,
       t.early_dropout_rate,
       t.transfer_rate,
       CAST(r.top_reason_count AS FLOAT) / t.discharges AS top_reason_share,
       u.national_rate,
       t.completion_rate - u.national_rate              AS gap_vs_national,
       -- z-score: how many standard deviations a state sits above or below the average state
       CASE WHEN t.discharges >= 1000
            THEN (t.completion_rate - p.peer_avg) / p.peer_sd END AS peer_z_score,
       CASE WHEN t.discharges < 1000                                 THEN 'Low volume (<1,000)'
            WHEN (t.completion_rate - p.peer_avg) / p.peer_sd <= -1.5 THEN 'Below peer range'
            WHEN (t.completion_rate - p.peer_avg) / p.peer_sd >= 1.5  THEN 'Above peer range'
            ELSE 'Within peer range' END                    AS completion_flag,
       -- if one reason covers 80%+ of a state's discharges, the state's coding practice is driving its rate
       CASE WHEN CAST(r.top_reason_count AS FLOAT) / t.discharges >= 0.80
            THEN 'Review: one reason is 80%+ of discharges'
            ELSE 'No reporting flag' END                    AS reporting_flag
FROM state_totals AS t
JOIN dw.dim_state AS st ON st.state_key = t.state_key
JOIN top_reason   AS r  ON r.state_key  = t.state_key
CROSS JOIN peer     AS p     -- peer and us_total have one row each, so CROSS JOIN adds them to every state
CROSS JOIN us_total AS u;
GO

-- Detail view: one row per discharge with every name Tableau can filter on (the Tableau extract source)
CREATE OR ALTER VIEW rpt.vw_discharge_detail AS
SELECT f.case_id,
       dt.calendar_year,
       st.state_name, st.state_abbr, st.census_region, st.census_division,
       ss.setting_label, ss.setting_group,
       sb.substance_label, sb.substance_group,
       dm.age_group, dm.age_band, dm.sex_label, dm.race_label, dm.ethnicity_label,
       ls.los_key, ls.los_label, ls.los_band_sort, ls.los_band,
       dr.reason_label, dr.reason_group,
       k.completion_flag AS state_completion_flag,
       k.reporting_flag  AS state_reporting_flag,
       f.discharge_count, f.completed_flag, f.dropout_flag, f.early_dropout_flag, f.terminated_flag, f.transfer_flag
FROM dw.fact_discharge            AS f
JOIN dw.dim_date                  AS dt ON dt.date_key            = f.date_key
JOIN dw.dim_state                 AS st ON st.state_key           = f.state_key
JOIN dw.dim_service_setting       AS ss ON ss.service_setting_key = f.service_setting_key
JOIN dw.dim_substance             AS sb ON sb.substance_key       = f.substance_key
JOIN dw.dim_demographic           AS dm ON dm.demographic_key     = f.demographic_key
JOIN dw.dim_length_of_stay        AS ls ON ls.los_key             = f.los_key
JOIN dw.dim_discharge_reason      AS dr ON dr.reason_key          = f.reason_key
JOIN rpt.vw_kpi2_state_completion AS k  ON k.state_key            = f.state_key;
GO

-- KPI 1: national scorecard (one row)
CREATE OR ALTER VIEW rpt.vw_kpi1_national_scorecard AS
SELECT COUNT(*)                                            AS discharges,
       SUM(completed_flag)                                 AS completed,
       SUM(dropout_flag)                                   AS dropouts,
       SUM(early_dropout_flag)                             AS early_dropouts,
       SUM(transfer_flag)                                  AS transfers,
       COUNT(DISTINCT state_key)                           AS jurisdictions,
       CAST(SUM(completed_flag) AS FLOAT) / COUNT(*)       AS completion_rate,
       CAST(SUM(dropout_flag) AS FLOAT) / COUNT(*)         AS dropout_rate,
       CAST(SUM(early_dropout_flag) AS FLOAT) / COUNT(*)   AS early_dropout_rate,
       CAST(SUM(early_dropout_flag) AS FLOAT) / SUM(dropout_flag) AS early_share_of_dropouts,
       CAST(SUM(transfer_flag) AS FLOAT) / COUNT(*)        AS transfer_rate,
       -- the same completion rate without the states that carry a reporting flag
       (SELECT CAST(SUM(completed) AS FLOAT) / SUM(discharges)
        FROM rpt.vw_kpi2_state_completion
        WHERE reporting_flag = 'No reporting flag')        AS completion_rate_excl_review_states,
       (SELECT COUNT(*)
        FROM rpt.vw_kpi2_state_completion
        WHERE reporting_flag <> 'No reporting flag')       AS states_flagged_for_review
FROM dw.fact_discharge;
GO

-- KPI 3: outcome rates by service setting
CREATE OR ALTER VIEW rpt.vw_kpi3_service_setting AS
SELECT ss.service_setting_key,
       ss.setting_label,
       ss.setting_group,
       COUNT(*)                                            AS discharges,
       CAST(SUM(f.completed_flag) AS FLOAT) / COUNT(*)     AS completion_rate,
       CAST(SUM(f.dropout_flag) AS FLOAT) / COUNT(*)       AS dropout_rate,
       CAST(SUM(f.early_dropout_flag) AS FLOAT) / COUNT(*) AS early_dropout_rate,
       CAST(SUM(f.transfer_flag) AS FLOAT) / COUNT(*)      AS transfer_rate
FROM dw.fact_discharge AS f
JOIN dw.dim_service_setting AS ss ON ss.service_setting_key = f.service_setting_key
GROUP BY ss.service_setting_key, ss.setting_label, ss.setting_group;
GO

-- KPI 4: outcome rates by length of stay band, for each setting group
CREATE OR ALTER VIEW rpt.vw_kpi4_length_of_stay AS
SELECT ss.setting_group,
       ls.los_band_sort,
       ls.los_band,
       COUNT(*)                                        AS discharges,
       SUM(f.completed_flag)                           AS completed,
       SUM(f.dropout_flag)                             AS dropouts,
       CAST(SUM(f.completed_flag) AS FLOAT) / COUNT(*) AS completion_rate,
       CAST(SUM(f.dropout_flag) AS FLOAT) / COUNT(*)   AS dropout_rate
FROM dw.fact_discharge AS f
JOIN dw.dim_service_setting AS ss ON ss.service_setting_key = f.service_setting_key
JOIN dw.dim_length_of_stay  AS ls ON ls.los_key             = f.los_key
GROUP BY ss.setting_group, ls.los_band_sort, ls.los_band;
GO

-- KPI 5: who completes. Four small GROUP BY queries stacked into one table with UNION ALL.
CREATE OR ALTER VIEW rpt.vw_kpi5_who_completes AS
SELECT 'Primary substance' AS dimension_name,
       sb.substance_group  AS member,
       COUNT(*)            AS discharges,
       CAST(SUM(f.completed_flag) AS FLOAT) / COUNT(*) AS completion_rate,
       CAST(SUM(f.dropout_flag) AS FLOAT) / COUNT(*)   AS dropout_rate
FROM dw.fact_discharge AS f
JOIN dw.dim_substance AS sb ON sb.substance_key = f.substance_key
GROUP BY sb.substance_group

UNION ALL

SELECT 'Age band', dm.age_band, COUNT(*),
       CAST(SUM(f.completed_flag) AS FLOAT) / COUNT(*),
       CAST(SUM(f.dropout_flag) AS FLOAT) / COUNT(*)
FROM dw.fact_discharge AS f
JOIN dw.dim_demographic AS dm ON dm.demographic_key = f.demographic_key
GROUP BY dm.age_band

UNION ALL

SELECT 'Sex', dm.sex_label, COUNT(*),
       CAST(SUM(f.completed_flag) AS FLOAT) / COUNT(*),
       CAST(SUM(f.dropout_flag) AS FLOAT) / COUNT(*)
FROM dw.fact_discharge AS f
JOIN dw.dim_demographic AS dm ON dm.demographic_key = f.demographic_key
GROUP BY dm.sex_label

UNION ALL

SELECT 'Race', dm.race_label, COUNT(*),
       CAST(SUM(f.completed_flag) AS FLOAT) / COUNT(*),
       CAST(SUM(f.dropout_flag) AS FLOAT) / COUNT(*)
FROM dw.fact_discharge AS f
JOIN dw.dim_demographic AS dm ON dm.demographic_key = f.demographic_key
GROUP BY dm.race_label;
GO

-- Quick check: completion_rate should be about 0.426
SELECT * FROM rpt.vw_kpi1_national_scorecard;
GO
