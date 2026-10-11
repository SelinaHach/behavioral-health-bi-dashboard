# How Many Patients Finish Addiction Treatment?
### Behavioral Health BI Dashboard · Microsoft SQL Server · Tableau Cloud

Of 1,474,025 substance use treatment discharges reported to SAMHSA for 2023, **42.6% completed treatment**. This project loads the full public file into a SQL Server star schema, gates it with 12 data-quality checks, and serves five KPI views to a Tableau Cloud dashboard built for field executives.

**Live preview:** web version of the dashboard, computed from the same views (`dashboard/behavioral_health_dashboard_standalone.html`)
**Tableau Cloud:** pending

## Findings

| | |
|---|---|
| **42.6%** national completion (627,897 of 1,474,025) | **22.0%** dropped out, **25.1%** transferred |
| **44.4%** of dropouts leave within 30 days, **24.8%** within 7 | Opioids **23.7%** completion vs alcohol **49.5%** |
| Detox hospital inpatient **78.5%** vs intensive outpatient **26.0%** | **5 states** flagged for reporting review |

**The headline rate depends on coding practice.** Arizona reports 190,499 discharges (12.9% of the file) at 99.2% completion. Kentucky and North Carolina code close to 90% of discharges as transfers; Louisiana codes 82.6% as dropouts. Without Arizona the national rate is 34.2%; without all five flagged states it is 41.3%. The dashboard lets users switch scope so a field leader compares like with like.

## Pipeline

```
tedsd_puf_2023.csv (1,474,025 rows x 76 columns)
  └─ 01 stg.teds_d_2023 ............ BULK INSERT, raw codes
  └─ 02 ref.*  ..................... code lookups + codebook frequency table (152 cells)
  └─ 03 dq.check_results ........... DQ01-DQ11 gate: stops the build on any failure
  └─ 04 dw.* star schema ........... fact_discharge + 7 dimensions, then DQ12 load integrity
  └─ 05 rpt.* views ................ detail extract source + 5 KPI views
       └─ Tableau Desktop extract ── published to Tableau Cloud
```

### Star schema (discharge grain)

| Table | Grain / key | Notes |
|---|---|---|
| `dw.fact_discharge` | one row per discharge (`CASEID`) | additive 0/1 flags: completed, dropout, early dropout, terminated, transfer |
| `dw.dim_state` | `STFIPS` | 49 jurisdictions, census region and division |
| `dw.dim_service_setting` | `SERVICES_D` | 8 settings, grouped into detox / residential / IOP / outpatient |
| `dw.dim_substance` | `SUB1` | 20 codes incl. unknown, grouped into 9 substance groups |
| `dw.dim_demographic` | age x sex x race x ethnicity | 1,419 combinations seen in the data |
| `dw.dim_date` | `DISYR` | the public file carries discharge year only |
| `dw.dim_length_of_stay` | `LOS` | days 1-30 exact, 31-37 SAMHSA ranges, 9 reporting bands |
| `dw.dim_discharge_reason` | `REASON` | 7 reasons, 5 reporting groups |

### Data-quality checks (all 12 pass)

| ID | Check | Expected |
|---|---|---|
| DQ01 | Row count vs codebook | 1,474,025 |
| DQ02 | Column count vs codebook Appendix A | 76 |
| DQ03 | Duplicate `CASEID` episodes | 0 |
| DQ04 | Blank (NULL) values in the 11 columns the model uses | 0 |
| DQ05 | Discharge year other than 2023 | 0 |
| DQ06 | Invalid state codes | 0 |
| DQ07 | Invalid or missing discharge reason | 0 |
| DQ08 | Invalid service setting | 0 |
| DQ09 | Invalid length of stay | 0 |
| DQ10 | Invalid substance / age / sex / race / ethnicity codes | 0 |
| DQ11 | Codebook counts (152) that disagree with loaded counts | 0 |
| DQ12 | Rows lost between staging and the fact table (foreign keys block orphan codes) | 0 |

The checks were also run against a deliberately corrupted copy of the file (a duplicate row, invalid codes, a NULL, a wrong year, an extra column). Checks DQ01-DQ11 all failed as intended and the gate stopped the build.

The SQL is written to be read top to bottom: plain SELECT, JOIN, GROUP BY, CASE WHEN and small CTEs, with a one-line comment above each step. No dynamic SQL or window functions.

### KPI views → dashboard tabs

| View | Tab | Answers |
|---|---|---|
| `rpt.vw_kpi1_national_scorecard` | 1 Scorecard | Headline rates and the national rate without flagged states |
| `rpt.vw_kpi2_state_completion` | 2 States | Completion by state, peer-range z-score, reporting-review flag |
| `rpt.vw_kpi3_service_setting` | 3 Service setting | Completion, dropout and transfer by setting |
| `rpt.vw_kpi4_length_of_stay` | 4 Length of stay | Rate by stay band, cumulative dropout curve by setting group |
| `rpt.vw_kpi5_who_completes` | 5 Who completes | Completion gap by substance, age, sex, race |

Metric definitions and filter behavior: `docs/Dashboard_User_Guide.pdf` (one page).

## Run it

1. Download the TEDS-D 2023 CSV bundle from SAMHSA ([data files](https://www.samhsa.gov/data/data-we-collect/teds-treatment-episode-data-set/datafiles)) and unzip `tedsd_puf_2023.csv`.
2. Start SQL Server 2017 or later.
   - **Windows:** SQL Server 2022 Developer edition + SSMS.
   - **Mac (Docker Desktop):**
     ```bash
     docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=YourStrong!Passw0rd" \
       -p 1433:1433 --name teds-sql --platform linux/amd64 \
       -d mcr.microsoft.com/mssql/server:2022-latest
     docker cp tedsd_puf_2023.csv teds-sql:/var/opt/mssql/data/
     ```
     Then set `@csv_path = N'/var/opt/mssql/data/tedsd_puf_2023.csv'` in script 01. Connect with Azure Data Studio, VS Code (mssql extension) or `sqlcmd` at `localhost,1433`.
3. Edit `@csv_path` in `sql/01_create_database_and_stage.sql`, then run `sql/00_run_all.sql` in SQLCMD mode (or scripts 01 to 05 in order).
   - **Mac shortcut:** put the CSV in `data_raw/`, copy `local_sql.env.example` to `local_sql.env` with your own password, then run `bash run_local_sql.sh`. It starts SQL Server 2022 in Docker, runs the whole pipeline and exports every view to `results/sqlserver/` (about 1 minute after the first image download).
4. Expect `ALL 12 CHECKS PASS` and `completion_rate = 0.426` in the final smoke test.
5. Build the Tableau workbook with `docs/TABLEAU_BUILD_GUIDE.md`.

## Repo layout

```
sql/        00_run_all, 01 stage, 02 reference, 03 DQ gate, 04 star schema, 05 reporting views
docs/       Dashboard_User_Guide.pdf, TABLEAU_BUILD_GUIDE.md
dashboard/  web preview of the dashboard (single HTML file)
results/    KPI view outputs as CSV + data-quality results
build/      Python helpers: codebook reference generator, DuckDB test harness, preview builder
ref/        codebook_freqs.csv (published codebook frequency tables)
```

`build/run_duckdb_mirror.py` replays the T-SQL scripts against DuckDB (via sqlglot) as a test harness; SQL Server is the target system.

## Caveats

- TEDS counts discharges (episodes), not unique patients. One person can have several episodes in a year.
- TEDS covers mainly publicly funded facilities, and states differ in what they report. Delaware, Montana and West Virginia did not report enough 2023 data to be included.
- State rates mix patient outcomes with state coding practice. SAMHSA notes that states define admissions differently, so absolute counts are not a valid basis for comparing states. The dashboard flags the clearest coding patterns rather than ranking states outright.
- Length of stay is computed from admission to last contact, with one day added to outpatient discharges.

**Source:** Substance Abuse and Mental Health Services Administration, Treatment Episode Data Set: Discharges (TEDS-D) 2023, public use file DS0001 v1.

Built by Selina Hach · [github.com/SelinaHach](https://github.com/SelinaHach)
