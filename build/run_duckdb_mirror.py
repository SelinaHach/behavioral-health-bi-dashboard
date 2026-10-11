"""Executes the T-SQL scripts in sql/ against DuckDB (via sqlglot T-SQL -> DuckDB transpile)
to validate logic and produce the numbers used in the dashboard. SQL Server remains the target;
this is a test harness. Statements that are SQL Server-only (USE, schema EXEC, BULK INSERT,
dynamic SQL) are replaced with equivalents noted inline."""
import re, sys, pathlib, duckdb, sqlglot
ROOT = pathlib.Path(__file__).resolve().parents[1]
DB = ROOT / "build" / "teds_mirror.duckdb"
if DB.exists(): DB.unlink()
con = duckdb.connect(str(DB))
for s in ["stg", "ref", "dw", "dq", "rpt"]:
    con.execute(f"CREATE SCHEMA {s}")
csv = ROOT / "data_raw" / "tedsd_puf_2023.csv"
con.execute(f"CREATE TABLE stg.teds_d_2023 AS SELECT * FROM read_csv('{csv}', header=true, types={{'CASEID':'INTEGER'}})")

def batches(path):
    txt = path.read_text()
    return [b for b in re.split(r"^\s*GO\s*$", txt, flags=re.M) if b.strip()]

def run(sql, label):
    try:
        for stmt in sqlglot.transpile(sql, read="tsql", write="duckdb"):
            if stmt.upper().startswith("CREATE TABLE"):
                stmt = stmt.replace(" NULLS FIRST", "")   # sqlglot artifact in key lists
            stmt = stmt.replace("INNER JOIN LATERAL (VALUES", "CROSS JOIN LATERAL (VALUES")   # CROSS APPLY has no ON clause
            con.execute(stmt)
    except Exception as e:
        print(f"FAIL [{label}]: {e}\n---\n{sql[:600]}\n"); raise

def run_file(name, skip=lambda b: False, patch=lambda b: b):
    for i, b in enumerate(batches(ROOT / "sql" / name)):
        if re.search(r"^\s*USE\s", b, re.M) and len(b.strip().splitlines()) <= 3 and "CREATE" not in b: continue
        b = re.sub(r"^\s*USE\s+TEDS_BI;\s*$", "", b, flags=re.M)
        if skip(b): continue
        run(patch(b), f"{name}#{i}")

# 02 reference tables
run_file("02_reference_tables.sql",
         patch=lambda b: b.replace("DROP TABLE IF EXISTS ref.state, ref.service_setting, ref.substance, ref.age_group, ref.sex, ref.race,\n    ref.ethnicity, ref.length_of_stay, ref.discharge_reason, dq.codebook_frequency;", ""))
import os
if os.environ.get("MUTATE"):   # fault-injection test: every gate check that can see these faults must FAIL
    con.execute("INSERT INTO stg.teds_d_2023 SELECT * FROM stg.teds_d_2023 LIMIT 1")                      # duplicate episode
    con.execute("INSERT INTO stg.teds_d_2023 SELECT * REPLACE (9999991 AS CASEID, 99 AS STFIPS, -9 AS REASON, 0 AS SEX, 99 AS LOS) FROM stg.teds_d_2023 LIMIT 1")  # bad codes
    con.execute("INSERT INTO stg.teds_d_2023 SELECT * REPLACE (9999992 AS CASEID, NULL AS LOS, 2022 AS DISYR, 9 AS SERVICES_D) FROM stg.teds_d_2023 LIMIT 1")  # null, wrong year, bad setting
    con.execute("ALTER TABLE stg.teds_d_2023 ADD COLUMN EXTRA_COL INTEGER")                                # schema drift
# 03 data-quality gate: computed column + dynamic SQL replaced
def p03(b):
    b = b.replace("DROP TABLE IF EXISTS dq.check_results;", "")
    b = re.sub(r",\s*status\s+AS \(.*?\),\s*run_at[^\n]*", "", b, flags=re.S)
    b = b.replace("DECLARE @codebook_rows BIGINT = 1474025, @codebook_vars INT = 76;", "")
    b = b.replace("@codebook_rows", "1474025").replace("@codebook_vars", "76")
    b = b.replace("INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'stg' AND TABLE_NAME = 'teds_d_2023'",
                  "information_schema.columns WHERE table_schema = 'stg' AND table_name = 'teds_d_2023'")
    b = re.sub(r"-- Gate:.*", "", b, flags=re.S)   # gate IF/THROW is SQL Server control flow; evaluated in Python below
    return b
run_file("03_data_quality_checks.sql", patch=p03, skip=lambda b: b.strip().startswith("-- 3b."))
gate = con.execute("select check_id from dq.check_results where expected<>actual order by 1").fetchall()
if gate:
    print("GATE FAILED (pipeline would stop here):", [g[0] for g in gate])
    for r in con.execute("select check_id, check_name, expected, actual from dq.check_results order by 1").fetchall(): print(r)
    sys.exit(0)
# 04 star schema + DQ12 (IDENTITY -> sequence default; multi-table DROP removed; TABLOCK hint removed)
def p04(b):
    b = re.sub(r"DROP TABLE IF EXISTS [^;]+;", "", b)
    b = b.replace("INT IDENTITY(1,1) PRIMARY KEY", "INT DEFAULT nextval('seq_demo') PRIMARY KEY")
    b = b.replace("WITH (TABLOCK)", "")
    b = re.sub(r"REFERENCES dw\.\w+ \(\w+\)", "", b)   # FK checks dropped for speed; DQ12 tests integrity instead
    b = re.sub(r"CREATE INDEX [^;]+;", "", b)
    return b
con.execute("CREATE SEQUENCE seq_demo START 1")
run_file("04_build_star_schema.sql", patch=p04, skip=lambda b: b.strip().startswith("-- 4k."))
# 05 views
def p05(b): return b.replace("CREATE OR ALTER VIEW", "CREATE OR REPLACE VIEW")
run_file("05_reporting_views.sql", patch=p05, skip=lambda b: b.strip().startswith("/* Smoke test */"))

dq = con.execute("select check_id, check_name, expected, actual, case when expected=actual then 'PASS' else 'FAIL' end from dq.check_results order by 1").fetchall()
for r in dq: print(r)
print("PASS count:", sum(r[4] == 'PASS' for r in dq), "of", len(dq))
