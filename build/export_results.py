"""Exports the KPI views to CSV (Tableau-ready fallback) and builds the compact JSON cube the HTML preview uses."""
import json, pathlib, duckdb
ROOT = pathlib.Path(__file__).resolve().parents[1]
con = duckdb.connect(str(ROOT / "build" / "teds_mirror.duckdb"), read_only=True)
out = ROOT / "results"
for v in ["vw_kpi1_national_scorecard", "vw_kpi2_state_completion", "vw_kpi3_service_setting",
          "vw_kpi4_length_of_stay", "vw_kpi5_who_completes"]:
    con.execute(f"COPY (SELECT * FROM rpt.{v}) TO '{out / (v + '.csv')}' (HEADER)")
con.execute(f"COPY (SELECT check_id, check_name, category, expected, actual, CASE WHEN expected=actual THEN 'PASS' ELSE 'FAIL' END AS status FROM dq.check_results ORDER BY 1) TO '{out / 'dq_check_results.csv'}' (HEADER)")

def rows(sql): 
    cur = con.execute(sql); cols = [d[0] for d in cur.description]
    return [list(r) for r in cur.fetchall()], cols
d = {}
d["states"], d["states_cols"] = rows("""select state_key, state_name, state_abbr, census_region, discharges, completion_flag, reporting_flag,
    round(top_reason_share,4) from rpt.vw_kpi2_state_completion order by state_name""")
d["settings"], _ = rows("select service_setting_key, setting_label, setting_group from dw.dim_service_setting order by 1")
d["reasons"], _ = rows("select reason_key, reason_label, reason_group from dw.dim_discharge_reason order by 1")
d["los_bands"], _ = rows("select distinct los_band_sort, los_band from dw.dim_length_of_stay order by 1")
d["cube_setting"], d["cube_setting_cols"] = rows("""select state_key, service_setting_key, sum(discharge_count)::int n, sum(completed_flag)::int c,
    sum(dropout_flag)::int d, sum(early_dropout_flag)::int e, sum(transfer_flag)::int t from dw.fact_discharge group by all order by 1,2""")
d["cube_reason"], _ = rows("select state_key, reason_key, count(*)::int n from dw.fact_discharge group by all order by 1,2")
d["cube_los"], _ = rows("""select f.state_key, ss.setting_group, ls.los_band_sort, sum(discharge_count)::int n, sum(completed_flag)::int c, sum(dropout_flag)::int d
    from dw.fact_discharge f join dw.dim_service_setting ss using (service_setting_key) join dw.dim_length_of_stay ls using (los_key) group by all order by 1,2,3""")
d["cube_who"], _ = rows("""select state_key, dim, member, sum(n)::int, sum(c)::int, sum(dd)::int from (
    select f.state_key, 'Primary substance' dim, sb.substance_group member, 1 n, completed_flag c, dropout_flag dd from dw.fact_discharge f join dw.dim_substance sb using (substance_key)
    union all select f.state_key, 'Age band', dm.age_band, 1, completed_flag, dropout_flag from dw.fact_discharge f join dw.dim_demographic dm using (demographic_key)
    union all select f.state_key, 'Sex', dm.sex_label, 1, completed_flag, dropout_flag from dw.fact_discharge f join dw.dim_demographic dm using (demographic_key)
    union all select f.state_key, 'Race', dm.race_label, 1, completed_flag, dropout_flag from dw.fact_discharge f join dw.dim_demographic dm using (demographic_key)
    ) group by all order by 1,2,3""")
d["dq"], _ = rows("select check_id, check_name, category, expected, actual from dq.check_results order by 1")
(out / "dashboard_data.json").write_text(json.dumps(d, separators=(",", ":")))
print({k: len(v) for k, v in d.items() if isinstance(v, list)})
print("json bytes", (out / "dashboard_data.json").stat().st_size)
