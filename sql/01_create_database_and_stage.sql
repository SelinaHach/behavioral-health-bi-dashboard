-- 01_create_database_and_stage.sql
-- Step 1: create the database and load the raw SAMHSA file into a staging table.
-- Data: TEDS-D 2023 (tedsd_puf_2023.csv), 1,474,025 rows x 76 columns.

-- 1a. Create the database if it does not exist yet
IF DB_ID('TEDS_BI') IS NULL
    CREATE DATABASE TEDS_BI;
GO

USE TEDS_BI;
GO

-- 1b. Create 5 schemas (think of them as folders), one per layer of the project:
--     stg = raw data, ref = lookup tables, dq = data checks, dw = star schema, rpt = views for Tableau
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('ref') IS NULL EXEC('CREATE SCHEMA ref');
IF SCHEMA_ID('dq')  IS NULL EXEC('CREATE SCHEMA dq');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('rpt') IS NULL EXEC('CREATE SCHEMA rpt');
GO

-- 1c. Staging table: one column per variable, in the same order as the CSV.
--     Every value is a number code (for example REASON 1 = completed). Missing values are coded -9.
DROP TABLE IF EXISTS stg.teds_d_2023;

CREATE TABLE stg.teds_d_2023 (
    DISYR INT, CASEID INT, STFIPS INT, EDUC INT, MARSTAT INT,
    SERVICES INT, DETCRIM INT, LOS INT, PSOURCE INT, NOPRIOR INT,
    ARRESTS INT, EMPLOY INT, METHUSE INT, PSYPROB INT, PREG INT,
    SEX INT, VET INT, LIVARAG INT, DAYWAIT INT, SERVICES_D INT,
    REASON INT, EMPLOY_D INT, LIVARAG_D INT, ARRESTS_D INT, DSMCRIT INT,
    AGE INT, RACE INT, ETHNIC INT, DETNLF INT, DETNLF_D INT,
    PRIMINC INT, SUB1 INT, SUB2 INT, SUB3 INT, SUB1_D INT,
    SUB2_D INT, SUB3_D INT, ROUTE1 INT, ROUTE2 INT, ROUTE3 INT,
    FREQ1 INT, FREQ2 INT, FREQ3 INT, FREQ1_D INT, FREQ2_D INT,
    FREQ3_D INT, FRSTUSE1 INT, FRSTUSE2 INT, FRSTUSE3 INT, HLTHINS INT,
    PRIMPAY INT, FREQ_ATND_SELF_HELP INT, FREQ_ATND_SELF_HELP_D INT, ALCFLG INT, COKEFLG INT,
    MARFLG INT, HERFLG INT, METHFLG INT, OPSYNFLG INT, PCPFLG INT,
    HALLFLG INT, MTHAMFLG INT, AMPHFLG INT, STIMFLG INT, BENZFLG INT,
    TRNQFLG INT, BARBFLG INT, SEDHPFLG INT, INHFLG INT, OTCFLG INT,
    OTHERFLG INT, DIVISION INT, REGION INT, IDU INT, ALCDRUG INT,
    CBSA2020 INT
);
GO

-- 1d. Load the whole CSV into the table in one go. FIRSTROW = 2 skips the header row.
--     Change the path to where your CSV is (on Windows, for example 'C:\TEDS\tedsd_puf_2023.csv').
BULK INSERT stg.teds_d_2023
FROM '/var/opt/mssql/data/tedsd_puf_2023.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2);
GO

-- 1e. Quick check: this should say 1,474,025
SELECT COUNT(*) AS rows_loaded
FROM stg.teds_d_2023;
GO
