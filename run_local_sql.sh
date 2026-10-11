#!/bin/bash
# Builds the whole TEDS_BI pipeline in a local SQL Server 2022 container (Docker Desktop).
# Usage:  bash run_local_sql.sh        Output: results/sqlserver/run_log.txt + exported view CSVs
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
set -a; source "$DIR/local_sql.env"; set +a
OUT="$DIR/results/sqlserver"; mkdir -p "$OUT"; LOG="$OUT/run_log.txt"
exec > >(tee "$LOG") 2>&1
echo "== $(date) =="
SQLCMD="/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $MSSQL_SA_PASSWORD -C"

echo "1/5 Starting SQL Server 2022 container (first run downloads ~1.5 GB)..."
docker rm -f teds-sql >/dev/null 2>&1 || true
docker run -d --name teds-sql --platform linux/amd64 -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$MSSQL_SA_PASSWORD" \
  -p 1433:1433 mcr.microsoft.com/mssql/server:2022-latest || { echo "FAILED: docker run"; exit 1; }

echo "2/5 Waiting for SQL Server to accept connections..."
for i in $(seq 1 60); do
  if docker exec teds-sql $SQLCMD -Q "SELECT 1" >/dev/null 2>&1; then echo "   ready after ~$((i*5))s"; break; fi
  sleep 5
  [ "$i" = 60 ] && { echo "FAILED: SQL Server did not start"; docker logs --tail 40 teds-sql; exit 1; }
done

echo "3/5 Copying scripts and data into the container..."
docker cp "$DIR/sql" teds-sql:/var/opt/mssql/work_sql
docker cp "$DIR/data_raw/tedsd_puf_2023.csv" teds-sql:/var/opt/mssql/data/tedsd_puf_2023.csv
docker exec -u 0 teds-sql bash -c "chown -R mssql /var/opt/mssql/work_sql /var/opt/mssql/data/tedsd_puf_2023.csv && chmod -R u+rw /var/opt/mssql/work_sql /var/opt/mssql/data/tedsd_puf_2023.csv"

echo "4/5 Running sql/00_run_all.sql (stage -> reference -> DQ gate -> star schema -> views)..."
START=$(date +%s)
docker exec -w /var/opt/mssql/work_sql teds-sql $SQLCMD -b -i 00_run_all.sql
RC=$?
echo "   exit code $RC, $(( $(date +%s) - START ))s"
[ $RC -ne 0 ] && { echo "FAILED: pipeline stopped (see messages above)"; exit $RC; }

echo "5/5 Exporting results..."
for q in "dq.check_results ORDER BY check_id:dq_check_results" "rpt.vw_kpi1_national_scorecard:vw_kpi1_national_scorecard" \
         "rpt.vw_kpi2_state_completion ORDER BY state_name:vw_kpi2_state_completion" "rpt.vw_kpi3_service_setting:vw_kpi3_service_setting" \
         "rpt.vw_kpi4_length_of_stay ORDER BY setting_group, los_band_sort:vw_kpi4_length_of_stay" \
         "rpt.vw_kpi5_who_completes ORDER BY dimension_name, member:vw_kpi5_who_completes"; do
  src="${q%%:*}"; name="${q##*:}"
  docker exec teds-sql $SQLCMD -d TEDS_BI -s "," -W -w 4000 -Q "SET NOCOUNT ON; SELECT * FROM $src" > "$OUT/$name.csv"
done
docker exec teds-sql $SQLCMD -d TEDS_BI -Q "SET NOCOUNT ON; SELECT @@VERSION AS sql_server_version; SELECT COUNT_BIG(*) AS fact_rows FROM dw.fact_discharge; SELECT completion_rate FROM rpt.vw_kpi1_national_scorecard;"
echo "DONE. SQL Server keeps running in Docker (container teds-sql, localhost,1433) for Tableau."
