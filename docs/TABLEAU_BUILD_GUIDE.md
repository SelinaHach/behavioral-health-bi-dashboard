# Tableau build guide

Step-by-step build of the five KPI views in Tableau Desktop, then publish to Tableau Cloud. Before you start, the SQL pipeline (`sql/00_run_all.sql`) must have run cleanly, with all 12 data-quality checks passing. The web preview (`dashboard/behavioral_health_dashboard_standalone.html`) shows the target layout and the numbers each view should match.

Time needed: about 3 to 4 hours.

## 0. What you need

| Item | Notes |
|---|---|
| SQL Server with `TEDS_BI` built | Windows: SQL Server 2022 Developer (free) + SSMS. Mac: SQL Server 2022 in Docker (see README). |
| Tableau Desktop | Mac or Windows. On first connect Tableau asks for the Microsoft SQL Server ODBC driver; install it from the link Tableau shows. |
| A Tableau Cloud site | You publish the workbook here. Tableau Cloud cannot reach a SQL Server on your laptop, so you publish an **extract** (snapshot). That suits this data: TEDS-D is an annual file. |

## 1. Connect and extract

1. Tableau Desktop > Connect > **Microsoft SQL Server**. Server `localhost` (Docker: `localhost,1433`), database `TEDS_BI`, SQL Server authentication.
2. Drag `rpt.vw_discharge_detail` to the canvas. Rename the data source **Discharges**.
3. Choose **Extract** (top right) > Edit > leave all rows > OK. Save the extract as `teds_discharges_2023.hyper`. Expect 1,474,025 rows.
4. Add a second data source: `dq.check_results`, renamed **Data Quality** (Live is fine before publishing; switch it to Extract as well).

## 2. Parameters

| Parameter | Type | Values | Default |
|---|---|---|---|
| `p_Scope` | String, List | All reporting · Exclude reporting-review states · Exclude Arizona | All reporting |
| `p_Breakdown` | String, List | Primary substance · Age band · Sex · Race | Primary substance |

Right-click each parameter > Show Parameter.

## 3. Calculated fields (Discharges data source)

```
// In Scope  (put on Filters in every sheet, set to True)
CASE [p_Scope]
  WHEN "All reporting" THEN TRUE
  WHEN "Exclude reporting-review states" THEN [state_reporting_flag] = "No reporting flag"
  WHEN "Exclude Arizona" THEN [state_abbr] <> "AZ"
END

// Discharges
SUM([discharge_count])

// Completion Rate        (format: Percentage, 1 decimal)
SUM([completed_flag]) / SUM([discharge_count])

// Dropout Rate
SUM([dropout_flag]) / SUM([discharge_count])

// Transfer Rate
SUM([transfer_flag]) / SUM([discharge_count])

// Early Dropout Share    (share of dropouts that left within 30 days)
SUM([early_dropout_flag]) / SUM([dropout_flag])

// Scope Completion Rate  (one number for the whole filtered scope; used for reference lines and gaps)
{ FIXED [In Scope] : SUM([completed_flag]) / SUM([discharge_count]) }
// Note: FIXED ignores dimension filters unless they are context filters.
// Right-click the In Scope, Census Region and State filters > Add to Context.

// Gap vs Scope (pp)
[Completion Rate] - ATTR([Scope Completion Rate])

// Breakdown Member
CASE [p_Breakdown]
  WHEN "Primary substance" THEN [substance_group]
  WHEN "Age band" THEN [age_band]
  WHEN "Sex" THEN [sex_label]
  WHEN "Race" THEN [race_label]
END

// Cumulative Share of Dropouts  (table calculation: compute using los_band)
RUNNING_SUM(SUM([dropout_flag])) / TOTAL(SUM([dropout_flag]))
```

Sort `los_band` by `los_band_sort` (right-click los_band > Sort > Field > los_band_sort, Minimum).

## 4. The five KPI sheets

Put **In Scope = True**, **census_region** and **state_name** on Filters in every sheet (apply the region and state filters to all sheets using this data source).

### View 1: Scorecard
- **KPI tiles** (5 small sheets or one sheet with Measure Names): Discharges, Completion Rate, Dropout Rate, Early Dropout Share, Transfer Rate. Text mark, large font. Check: 1,474,025 / 42.6% / 22.0% / 44.4% / 25.1% at All reporting.
- **How discharges end:** `reason_group` on Color, `SUM(discharge_count)` on Columns, Quick Table Calculation > Percent of Total. One horizontal 100% bar. Order: Completed, Dropped out, Transferred, Terminated by facility, Other exit.

### View 2: States
- Rows: `state_name`. Columns: `Completion Rate`. Bar mark, sorted descending.
- Reference line: Analytics pane > Reference Line > Entire Table > `Scope Completion Rate`, label "Scope rate".
- Detail: `state_completion_flag`, `state_reporting_flag`. Add a second axis-free text column with the flags, or put `state_reporting_flag` on Shape (triangle for "Review").
- Tooltip: Discharges, Completion, Dropout, Transfer rate, both flags.
- Check: Arizona 99.2%, Nebraska 66.0%, Kentucky 5.0%, flags on AZ, KY, LA, MD, NC.

### View 3: Service setting
- Rows: `setting_label`. Columns: Measure Values filtered to Completion Rate, Dropout Rate, Transfer Rate. Color: Measure Names. Sort by Completion Rate descending.
- Label the completion bar only.
- Check: Detox 24-hour hospital inpatient 78.5%, Ambulatory intensive outpatient 26.0%.

### View 4: Length of stay
- **Rate by stay:** Columns `los_band` (sorted by los_band_sort). Rows Measure Values (Completion Rate, Dropout Rate). Line mark. Filter `setting_group` (show as single-value dropdown with "All").
- **When dropouts leave:** Columns `los_band`, Rows `Cumulative Share of Dropouts`. Line mark, axis fixed 0 to 100%.
- Check: 1-day band 26.9% completion; 44.4% of dropouts gone by 15-30 days.

### View 5: Who completes
- Rows `Breakdown Member`, Columns `Gap vs Scope (pp)`. Bar mark. Color: calculated field `[Gap vs Scope (pp)] >= 0` (True = blue, False = orange).
- Label: Completion Rate and Discharges.
- Caption: "Arizona supplies 81% of records with an unknown primary substance."
- Check at All reporting, Primary substance: Opioids 23.7%, Alcohol 49.5%.

### Data quality tab (optional sixth sheet)
- From **Data Quality**: table of `check_id`, `check_name`, `category`, `expected`, `actual`, `status`. Color `status`.

## 5. Dashboard assembly

1. New Dashboard, Size: Automatic (or 1200 x 900 fixed).
2. Header: title "How Many Patients Finish Addiction Treatment?" and the Completion Rate tile large on the right.
3. Filter row across the top: `p_Scope` parameter, Census region, State. Set filters to "Apply to worksheets > All using this data source".
4. Five tabs: easiest is five dashboards (Scorecard, States, Service setting, Length of stay, Who completes) each with the same filter row, published with **Show sheets as tabs**.
5. Footer text box: source line (SAMHSA TEDS-D 2023, DS0001 v1; DE, MT, WV not reported).

## 6. Publish to Tableau Cloud

1. Server > Sign In > your Tableau Cloud site URL.
2. Server > Publish Workbook. Project: your choice. Name: `Behavioral Health BI Dashboard`.
3. Data sources: Publish Type **Embedded in workbook**, Authentication **Embedded** (extract only, no live connection needed).
4. Tick **Show sheets as tabs**. Publish.
5. Share > copy link. Attach `docs/Dashboard_User_Guide.pdf` to the workbook description or the project.
6. Screenshot each tab for the GitHub README.

## 7. Match check before you call it done

| Number | Where | Expected |
|---|---|---|
| Discharges | View 1 tile | 1,474,025 |
| Completion rate | View 1 tile | 42.6% |
| Excluding review states | View 1, p_Scope switched | 41.3% |
| Excluding Arizona | View 1, p_Scope switched | 34.2% |
| Early dropout share | View 1 tile | 44.4% |
| States flagged for review | View 2 | 5 (AZ, KY, LA, MD, NC) |
| Detox hospital inpatient | View 3 | 78.5% |
| Opioids | View 5 | 23.7% |
