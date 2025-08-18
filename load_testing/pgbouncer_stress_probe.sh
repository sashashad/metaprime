#!/usr/bin/env bash
set -euo pipefail

DB="${DB:-pgbench}"
APP_USER="${APP_USER:-app}"
APP_PASS="${APP_PASS:-app_pass}"
PGB_HOST="${PGB_HOST:-localhost}"
PGB_PORT="${PGB_PORT:-6432}"
DUR="${DUR:-60}"
JOBS="${JOBS:-8}"
SAMPLE="${SAMPLE:-2}"
CLIENT_STEPS="${CLIENT_STEPS:-50 100 200 400 600 800 1000}"

if [[ -n "${WORKLOADS:-}" ]]; then
  IFS=' ' read -r -a WORKLOADS <<< "$WORKLOADS"
else
  WORKLOADS=("ro" "rw" "sleep")
fi

TS=$(date +%Y%m%d_%H%M%S)
OUTDIR="stress_results_${TS}"
mkdir -p "$OUTDIR"
CSV="${OUTDIR}/summary.csv"
echo "timestamp,workload,clients,tps_incl,tps_excl,lat_avg_ms,stddev_ms,failures,cl_waiting_peak,sv_active_peak" > "$CSV"

PROFILE_FILE="${OUTDIR}/workload_profile.txt"
echo "WORKLOADS: ${WORKLOADS[*]}" > "$PROFILE_FILE"
echo "CLIENT_STEPS: ${CLIENT_STEPS}" >> "$PROFILE_FILE"
echo "DUR: ${DUR}" >> "$PROFILE_FILE"
echo "JOBS: ${JOBS}" >> "$PROFILE_FILE"
echo "SAMPLE: ${SAMPLE}" >> "$PROFILE_FILE"

pgb() { PGPASSWORD="$APP_PASS" psql -h "$PGB_HOST" -p "$PGB_PORT" -U "$APP_USER" -v ON_ERROR_STOP=1 "$@"; }

sample_pgbouncer () {
  local log="$1"
  while :; do
    echo "## $(date -Is)" >> "$log"
    echo "__POOLS__" >> "$log"
    pgb -d pgbouncer -Atc "SHOW POOLS;" >> "$log" 2>&1 || true
    echo >> "$log"
    echo "__STATS__" >> "$log"
    pgb -d pgbouncer -Atc "SHOW STATS;" >> "$log" 2>&1 || true
    echo >> "$log"
    echo "__LISTS__" >> "$log"
    pgb -d pgbouncer -Atc "SHOW LISTS;" >> "$log" 2>&1 || true
    echo >> "$log"
    sleep "$SAMPLE"
  done
}

extract_peaks () {
  local log="$1"
  sed -n '/^__POOLS__$/,/^__/p' "$log" \
  | sed '1d;$d' \
  | awk -F'|' 'BEGIN{cw=0;sa=0} NF>=7{ if($4+0>cw) cw=$4+0; if($7+0>sa) sa=$7+0 } END{print cw,sa}'
}

run_step () {
  local workload="$1" clients="$2"
  local flags mode script_file=""
  case "$workload" in
    ro) flags="-S"; mode="simple" ;;
    rw) flags="-N"; mode="simple" ;;
    sleep)
      mode="simple"
      script_file="${OUTDIR}/sleep.sql"
      echo "SELECT pg_sleep(0.5);" > "$script_file"
      flags="-f $script_file"
      ;;
  esac

  local tag="${workload}_c${clients}"
  local pgb_log="${OUTDIR}/pgb_${tag}.log"
  local bench_log="${OUTDIR}/pgbench_${tag}.log"

  echo "[*] Run $tag  DUR=${DUR}s"
  sample_pgbouncer "$pgb_log" & sampler_pid=$!

  set +e
  RES=$(LC_ALL=C PGPASSWORD="$APP_PASS" pgbench -h "$PGB_HOST" -p "$PGB_PORT" -U "$APP_USER" \
         -M "$mode" $flags -c "$clients" -j "$JOBS" -T "$DUR" -P 5 "$DB" 2>&1)
  set -e

  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true

  echo "$RES" > "$bench_log"

  # Parse metrics (robust to locale; fallback to last progress line)
  tps_incl=$(echo "$RES" | awk -F'=' '/tps = .*including connections/ {gsub(/ .*$/,"",$2); print $2}' | tail -1 | tr ',' '.')
  tps_excl=$(echo "$RES" | awk -F'=' '/tps = .*excluding connections/ {gsub(/ .*$/,"",$2); print $2}' | tail -1 | tr ',' '.')
  lat=$(echo   "$RES" | awk -F'=' '/latency average/ {gsub(/ ms/,"",$2); print $2}' | tail -1 | tr ',' '.')
  std=$(echo   "$RES" | awk -F'=' '/latency stddev/  {gsub(/ ms/,"",$2); print $2}' | tail -1 | tr ',' '.')

  if [[ -z "$tps_excl" && -z "$tps_incl" ]]; then
    PROG_LAST=$(echo "$RES" | awk '/^progress:/ {line=$0} END{print line}')
    if [[ -n "$PROG_LAST" ]]; then
      tps_prog=$(echo "$PROG_LAST" | grep -Eo '[0-9]+([.,][0-9]+)? tps' | awk '{print $1}' | tr ',' '.')
      lat_prog=$(echo "$PROG_LAST" | grep -Eo 'lat [0-9]+([.,][0-9]+)? ms' | awk '{print $2}' | tr ',' '.')
      std_prog=$(echo "$PROG_LAST" | grep -Eo 'stddev [0-9]+([.,][0-9]+)?' | awk '{print $2}' | tr ',' '.')
      tps_incl="${tps_prog:-0}"; tps_excl="${tps_prog:-0}"
      lat="${lat:-${lat_prog:-0}}"; std="${std:-${std_prog:-0}}"
    fi
  fi

  tps_incl=${tps_incl:-0}; tps_excl=${tps_excl:-0}; lat=${lat:-0}; std=${std:-0}
  fails=$(echo "$RES" | grep -cE "could not connect|server closed|timeout|ERROR:" || true)

  read clp svp < <(extract_peaks "$pgb_log")
  echo "$(date -Is),$workload,$clients,$tps_incl,$tps_excl,$lat,$std,$fails,$clp,$svp" >> "$CSV"

  if [[ ${clp:-0} -gt 0 || ${fails:-0} -gt 0 ]]; then
    echo "[!] Saturation or errors detected at $tag  (cl_waiting_peak=$clp, failures=$fails)"
  fi
}

for w in "${WORKLOADS[@]}"; do
  for c in $CLIENT_STEPS; do
    run_step "$w" "$c"
  done
done

echo "Done. Summary: $CSV  Logs: $OUTDIR/  Profile: $PROFILE_FILE"
