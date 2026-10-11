-- 04_build_star_schema.sql
-- Step 4: reshape the raw table into a star schema.
--   Fact table      = one row per discharge (1,474,025 rows), holding codes and 0/1 flags.
--   Dimension tables = the names and groups we slice by: state, setting, substance,
--                      demographic, year, length of stay, discharge reason.

USE TEDS_BI;
GO

-- 4a. Remove old versions so the file can be run again (fact first, because it points to the dimensions)
DROP TABLE IF EXISTS dw.fact_discharge;
DROP TABLE IF EXISTS dw.dim_date, dw.dim_state, dw.dim_service_setting, dw.dim_substance,
                     dw.dim_demographic, dw.dim_length_of_stay, dw.dim_discharge_reason;
GO

-- 4b. Date dimension. The public file only has the discharge YEAR, so this table has one row: 2023.
CREATE TABLE dw.dim_date (
    date_key      INT PRIMARY KEY,   -- the year, e.g. 2023
    calendar_year INT
);

INSERT INTO dw.dim_date
SELECT DISTINCT DISYR, DISYR
FROM stg.teds_d_2023;

-- 4c. State dimension: name, abbreviation and Census region
CREATE TABLE dw.dim_state (
    state_key       INT PRIMARY KEY,   -- STFIPS code
    state_name      NVARCHAR(40),
    state_abbr      CHAR(2),
    census_region   NVARCHAR(20),
    census_division NVARCHAR(30)
);

INSERT INTO dw.dim_state
SELECT s.stfips, s.state_name, s.state_abbr,
       CASE r.REGION WHEN 0 THEN 'U.S. territories' WHEN 1 THEN 'Northeast' WHEN 2 THEN 'Midwest'
                     WHEN 3 THEN 'South' WHEN 4 THEN 'West' END,
       CASE r.DIVISION WHEN 0 THEN 'U.S. territories' WHEN 1 THEN 'New England' WHEN 2 THEN 'Middle Atlantic'
                       WHEN 3 THEN 'East North Central' WHEN 4 THEN 'West North Central' WHEN 5 THEN 'South Atlantic'
                       WHEN 6 THEN 'East South Central' WHEN 7 THEN 'West South Central' WHEN 8 THEN 'Mountain'
                       WHEN 9 THEN 'Pacific' END
FROM ref.state AS s
JOIN (SELECT DISTINCT STFIPS, REGION, DIVISION FROM stg.teds_d_2023) AS r
  ON r.STFIPS = s.stfips;

-- 4d. Service setting dimension (setting at discharge), copied from the lookup table
CREATE TABLE dw.dim_service_setting (
    service_setting_key INT PRIMARY KEY,   -- SERVICES_D code
    setting_label       NVARCHAR(80),
    setting_group       NVARCHAR(40)
);

INSERT INTO dw.dim_service_setting
SELECT services_d, setting_label, setting_group
FROM ref.service_setting;

-- 4e. Substance dimension (primary substance at admission)
CREATE TABLE dw.dim_substance (
    substance_key   INT PRIMARY KEY,   -- SUB1 code
    substance_label NVARCHAR(60),
    substance_group NVARCHAR(40)
);

INSERT INTO dw.dim_substance
SELECT sub_code, substance_label, substance_group
FROM ref.substance;

-- 4f. Demographic dimension: one row per combination of age group, sex, race and ethnicity
--     that appears in the data. IDENTITY(1,1) numbers the rows automatically: 1, 2, 3...
CREATE TABLE dw.dim_demographic (
    demographic_key INT IDENTITY(1,1) PRIMARY KEY,
    age             INT,
    age_group       NVARCHAR(30),
    age_band        NVARCHAR(20),
    sex             INT,
    sex_label       NVARCHAR(50),
    race            INT,
    race_label      NVARCHAR(60),
    ethnic          INT,
    ethnicity_label NVARCHAR(60)
);

INSERT INTO dw.dim_demographic (age, age_group, age_band, sex, sex_label, race, race_label, ethnic, ethnicity_label)
SELECT d.AGE, a.age_label,
       CASE WHEN d.AGE <= 2 THEN 'Under 18'
            WHEN d.AGE <= 4 THEN '18-24'
            WHEN d.AGE <= 6 THEN '25-34'
            WHEN d.AGE <= 8 THEN '35-44'
            WHEN d.AGE <= 10 THEN '45-54'
            ELSE '55+' END,
       d.SEX, x.sex_label, d.RACE, r.race_label, d.ETHNIC, e.ethnicity_label
FROM (SELECT DISTINCT AGE, SEX, RACE, ETHNIC FROM stg.teds_d_2023) AS d
JOIN ref.age_group AS a ON a.age    = d.AGE
JOIN ref.sex       AS x ON x.sex    = d.SEX
JOIN ref.race      AS r ON r.race   = d.RACE
JOIN ref.ethnicity AS e ON e.ethnic = d.ETHNIC;

-- 4g. Length of stay dimension: codes 1-30 are days, 31-37 are ranges. Grouped into 9 bands.
CREATE TABLE dw.dim_length_of_stay (
    los_key       INT PRIMARY KEY,   -- LOS code
    los_label     NVARCHAR(30),
    los_band_sort INT,
    los_band      NVARCHAR(30)
);

INSERT INTO dw.dim_length_of_stay
SELECT los, los_label, los_band_sort, los_band
FROM ref.length_of_stay;

-- 4h. Discharge reason dimension
CREATE TABLE dw.dim_discharge_reason (
    reason_key   INT PRIMARY KEY,   -- REASON code
    reason_label NVARCHAR(70),
    reason_group NVARCHAR(30)
);

INSERT INTO dw.dim_discharge_reason
SELECT reason, reason_label, reason_group
FROM ref.discharge_reason;
GO

-- 4i. Fact table: one row per discharge.
--     The _key columns point to the dimensions (REFERENCES makes SQL Server reject a code that is not there).
--     The _flag columns are 1 or 0, so SUM(flag) = how many, and SUM(flag) / COUNT(*) = the rate.
CREATE TABLE dw.fact_discharge (
    case_id             INT PRIMARY KEY,
    date_key            INT REFERENCES dw.dim_date (date_key),
    state_key           INT REFERENCES dw.dim_state (state_key),
    service_setting_key INT REFERENCES dw.dim_service_setting (service_setting_key),
    substance_key       INT REFERENCES dw.dim_substance (substance_key),
    demographic_key     INT REFERENCES dw.dim_demographic (demographic_key),
    los_key             INT REFERENCES dw.dim_length_of_stay (los_key),
    reason_key          INT REFERENCES dw.dim_discharge_reason (reason_key),
    discharge_count     INT,   -- always 1
    completed_flag      INT,   -- 1 if REASON = 1 (treatment completed)
    dropout_flag        INT,   -- 1 if REASON = 2 (dropped out)
    early_dropout_flag  INT,   -- 1 if dropped out within the first 30 days
    terminated_flag     INT,   -- 1 if REASON = 3 (terminated by facility)
    transfer_flag       INT    -- 1 if REASON = 4 (transferred)
);

INSERT INTO dw.fact_discharge
SELECT s.CASEID,
       s.DISYR,
       s.STFIPS,
       s.SERVICES_D,
       s.SUB1,
       d.demographic_key,
       s.LOS,
       s.REASON,
       1,
       CASE WHEN s.REASON = 1 THEN 1 ELSE 0 END,
       CASE WHEN s.REASON = 2 THEN 1 ELSE 0 END,
       CASE WHEN s.REASON = 2 AND s.LOS <= 30 THEN 1 ELSE 0 END,
       CASE WHEN s.REASON = 3 THEN 1 ELSE 0 END,
       CASE WHEN s.REASON = 4 THEN 1 ELSE 0 END
FROM stg.teds_d_2023 AS s
JOIN dw.dim_demographic AS d
  ON d.age = s.AGE AND d.sex = s.SEX AND d.race = s.RACE AND d.ethnic = s.ETHNIC;
GO

-- 4j. DQ12: no rows were lost on the way from staging to the fact table
INSERT INTO dq.check_results
SELECT 'DQ12', 'Rows lost between staging and the fact table', 'Integrity', 0,
       (SELECT COUNT(*) FROM stg.teds_d_2023) - (SELECT COUNT(*) FROM dw.fact_discharge);
GO

-- 4k. Show all 12 checks
SELECT check_id, check_name, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS status
FROM dq.check_results
ORDER BY check_id;
GO
