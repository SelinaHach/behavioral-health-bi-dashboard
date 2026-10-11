-- 00_run_all.sql
-- Runs files 01 to 05 in order. Needs SQLCMD mode (the :r lines are sqlcmd commands, not SQL).
--   Terminal:  sqlcmd -S localhost -U sa -P "<password>" -C -b -i 00_run_all.sql
--   On a Mac:  bash run_local_sql.sh   (does this for you inside Docker)
-- In VS Code, open and run the five files one by one instead.
:on error exit
:r 01_create_database_and_stage.sql
:r 02_reference_tables.sql
:r 03_data_quality_checks.sql
:r 04_build_star_schema.sql
:r 05_reporting_views.sql
PRINT 'Pipeline complete. Connect Tableau to the TEDS_BI.rpt views.';
GO
