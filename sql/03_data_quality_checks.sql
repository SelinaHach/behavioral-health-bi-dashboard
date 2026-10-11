-- 03_data_quality_checks.sql
-- Step 3: check the raw data BEFORE building anything with it.
-- Each check counts something and saves two numbers: what we expected and what we actually found.
-- A check passes when expected = actual. Check DQ12 runs at the end of file 04.

USE TEDS_BI;
GO

-- 3a. Table that stores the result of every check
DROP TABLE IF EXISTS dq.check_results;

CREATE TABLE dq.check_results (
    check_id   VARCHAR(4),
    check_name VARCHAR(100),
    category   VARCHAR(20),
    expected   BIGINT,
    actual     BIGINT
);
GO

-- DQ01: the row count matches the codebook (1,474,025 records)
INSERT INTO dq.check_results
SELECT 'DQ01', 'Row count matches the codebook', 'Completeness', 1474025, COUNT(*)
FROM stg.teds_d_2023;

-- DQ02: the column count matches the codebook (76 variables)
INSERT INTO dq.check_results
SELECT 'DQ02', 'Column count matches the codebook', 'Completeness', 76, COUNT(*)
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'stg' AND TABLE_NAME = 'teds_d_2023';

-- DQ03: no duplicate episodes. Total rows minus distinct CASEIDs should be 0.
INSERT INTO dq.check_results
SELECT 'DQ03', 'Duplicate CASEIDs', 'Uniqueness', 0, COUNT(*) - COUNT(DISTINCT CASEID)
FROM stg.teds_d_2023;

-- DQ04: no blank (NULL) values in the 11 columns this project uses
INSERT INTO dq.check_results
SELECT 'DQ04', 'Blank values in the columns we use', 'Completeness', 0, COUNT(*)
FROM stg.teds_d_2023
WHERE CASEID IS NULL OR DISYR IS NULL OR STFIPS IS NULL OR SERVICES_D IS NULL
   OR REASON IS NULL OR LOS IS NULL OR SUB1 IS NULL
   OR AGE IS NULL OR SEX IS NULL OR RACE IS NULL OR ETHNIC IS NULL;

-- DQ05: every record is a 2023 discharge
INSERT INTO dq.check_results
SELECT 'DQ05', 'Discharge year is not 2023', 'Validity', 0, COUNT(*)
FROM stg.teds_d_2023
WHERE DISYR <> 2023;

-- DQ06 to DQ10: every code must exist in its lookup table from file 02
INSERT INTO dq.check_results
SELECT 'DQ06', 'Invalid state codes', 'Validity', 0, COUNT(*)
FROM stg.teds_d_2023
WHERE STFIPS NOT IN (SELECT stfips FROM ref.state);

INSERT INTO dq.check_results
SELECT 'DQ07', 'Invalid discharge reason codes', 'Validity', 0, COUNT(*)
FROM stg.teds_d_2023
WHERE REASON NOT IN (SELECT reason FROM ref.discharge_reason);

INSERT INTO dq.check_results
SELECT 'DQ08', 'Invalid service setting codes', 'Validity', 0, COUNT(*)
FROM stg.teds_d_2023
WHERE SERVICES_D NOT IN (SELECT services_d FROM ref.service_setting);

INSERT INTO dq.check_results
SELECT 'DQ09', 'Invalid length of stay codes', 'Validity', 0, COUNT(*)
FROM stg.teds_d_2023
WHERE LOS NOT IN (SELECT los FROM ref.length_of_stay);

INSERT INTO dq.check_results
SELECT 'DQ10', 'Invalid substance, age, sex, race or ethnicity codes', 'Validity', 0, COUNT(*)
FROM stg.teds_d_2023
WHERE SUB1   NOT IN (SELECT sub_code FROM ref.substance)
   OR AGE    NOT IN (SELECT age      FROM ref.age_group)
   OR SEX    NOT IN (SELECT sex      FROM ref.sex)
   OR RACE   NOT IN (SELECT race     FROM ref.race)
   OR ETHNIC NOT IN (SELECT ethnic   FROM ref.ethnicity);
GO

-- DQ11: our counts match the 152 counts printed in the codebook.
-- Step 1 (loaded): count the rows per code for 9 variables, stacked into one list with UNION ALL.
-- Step 2: join that list to the codebook counts and count the numbers that do not match.
WITH loaded AS (
    SELECT 'STFIPS' AS variable_name, STFIPS AS code, COUNT(*) AS loaded_count FROM stg.teds_d_2023 GROUP BY STFIPS
    UNION ALL
    SELECT 'SERVICES_D', SERVICES_D, COUNT(*) FROM stg.teds_d_2023 GROUP BY SERVICES_D
    UNION ALL
    SELECT 'SUB1', SUB1, COUNT(*) FROM stg.teds_d_2023 GROUP BY SUB1
    UNION ALL
    SELECT 'AGE', AGE, COUNT(*) FROM stg.teds_d_2023 GROUP BY AGE
    UNION ALL
    SELECT 'SEX', SEX, COUNT(*) FROM stg.teds_d_2023 GROUP BY SEX
    UNION ALL
    SELECT 'RACE', RACE, COUNT(*) FROM stg.teds_d_2023 GROUP BY RACE
    UNION ALL
    SELECT 'ETHNIC', ETHNIC, COUNT(*) FROM stg.teds_d_2023 GROUP BY ETHNIC
    UNION ALL
    SELECT 'LOS', LOS, COUNT(*) FROM stg.teds_d_2023 GROUP BY LOS
    UNION ALL
    SELECT 'REASON', REASON, COUNT(*) FROM stg.teds_d_2023 GROUP BY REASON
)
INSERT INTO dq.check_results
SELECT 'DQ11', 'Codebook counts that do not match our counts', 'Reconciliation', 0, COUNT(*)
FROM dq.codebook_frequency AS c
LEFT JOIN loaded AS l
       ON l.variable_name = c.variable_name AND l.code = c.code
WHERE l.loaded_count IS NULL OR l.loaded_count <> c.codebook_count;
GO

-- 3b. Show the results
SELECT check_id, check_name, expected, actual,
       CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS status
FROM dq.check_results
ORDER BY check_id;
GO

-- Gate: stop here if any check failed, so bad data never reaches the star schema
IF EXISTS (SELECT 1 FROM dq.check_results WHERE expected <> actual)
    THROW 50001, 'A data-quality check failed. Fix the data before running file 04.', 1;
GO
