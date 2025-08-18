#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="$(pwd)"
LOG_DIR="${RUN_DIR}/logs"
mkdir -p "$LOG_DIR"
LOGFILE="${LOG_DIR}/pgb_capacity_guard_$(date +%F_%H-%M-%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "# Log file: ${LOGFILE}"

PGB_HOST="${PGB_HOST:-172.16.51.176}"
PGB_PORT="${PGB_PORT:-6432}"
PGB_USER="${PGB_USER:-app}"
PGB_PASS="${PGB_PASS:-app_pass}"

CA_IDX="${CA_IDX:-3}"
CW_IDX="${CW_IDX:-4}"
SA_IDX="${SA_IDX:-7}"
SI_IDX="${SI_IDX:-10}"

EXCLUDE_DBS="${EXCLUDE_DBS:-^(pgbouncer|template0|template1)$}"
EXCLUDE_USERS="${EXCLUDE_USERS:-^(pgbouncer)$}"
INCLUDE_DBS="${INCLUDE_DBS:-}"
INCLUDE_USERS="${INCLUDE_USERS:-}"

PG_HOST="${PG_HOST:-172.16.51.176}"
PG_PORT="${PG_PORT:-6432}"
PG_DB="${PG_DB:-postgres}"
PG_USER="${PG_USER:-postgres}"
PG_PASS="${PG_PASS:-}"
PG_FETCH="${PG_FETCH:-0}"
PG_SHOW_USAGE="${PG_SHOW_USAGE:-1}"

INTERVAL="${INTERVAL:-5}"
ONESHOT="${ONESHOT:-0}"

pgb() { PGPASSWORD="$PGB_PASS" psql --no-psqlrc -h "$PGB_HOST" -p "$PGB_PORT" -U "$PGB_USER" -d pgbouncer -q -Atc "$1"; }
pg()  { PGPASSWORD="$PG_PASS"  psql --no-psqlrc -h "$PG_HOST"  -p "$PG_PORT"  -U "$PG_USER"  -d "$PG_DB"    -q -Atc "$1"; }

fetch_pgb_config() {
  local cfg
  cfg="$(pgb "SHOW CONFIG;")" || return 1
  DEFAULT_POOL=$(awk -F'|' '$1=="default_pool_size"{print $2}' <<<"$cfg")
  RESERVE_POOL=$(awk -F'|' '$1=="reserve_pool_size"{print $2}' <<<"$cfg")
  : "${DEFAULT_POOL:=50}"
  : "${RESERVE_POOL:=0}"
}

fetch_pg_limits() {
  if [[ "$PG_FETCH" == "1" ]]; then
    local rows
    rows="$(pg "SHOW max_connections; SELECT current_setting('superuser_reserved_connections');" 2>/dev/null || true)"
    PG_MAX_CONNS=$(head -n1 <<<"$rows")
    PG_SUPER_RES=$(tail -n1 <<<"$rows")
    [[ -z "${PG_MAX_CONNS:-}" ]] && PG_MAX_CONNS=300
    [[ -z "${PG_SUPER_RES:-}" ]] && PG_SUPER_RES=3
  else
    PG_MAX_CONNS="${PG_MAX_CONNS:-300}"
    PG_SUPER_RES="${PG_SUPER_RES:-3}"
  fi
  PG_BUDGET=$(( PG_MAX_CONNS - PG_SUPER_RES ))
}

pg_current_used() {
  local c
  c=$(pg "SELECT count(*) FROM pg_stat_activity WHERE datname IS NOT NULL AND datname <> 'pgbouncer';" 2>&1) || { echo "ERR:$c"; return 0; }
  echo "$c"
}

snapshot() {
  local now pools
  now=$(date -Is)
  pools="$(pgb "SHOW POOLS;")" || { echo "[$now] ERROR: can't run SHOW POOLS" >&2; return 1; }

  awk -F'|' -v ts="$now" \
           -v exdb="$EXCLUDE_DBS" -v exusr="$EXCLUDE_USERS" \
           -v incdb="$INCLUDE_DBS" -v incusr="$INCLUDE_USERS" \
           -v CA="$CA_IDX" -v CW="$CW_IDX" -v SA="$SA_IDX" -v SI="$SI_IDX" '
    function num(v){ return (v ~ /^[0-9]+$/) ? v+0 : 0 }
    $1!~exdb && $2!~exusr && (incdb=="" || $1~incdb) && (incusr=="" || $2~incusr) {
      ca=num($(CA)); cw=num($(CW)); sa=num($(SA)); si=num($(SI));
      key=$1 "|" $2; seen[key]=1;
      SUM_CA+=ca; SUM_CW+=cw; SUM_SA+=sa; SUM_SI+=si;
    }
    END{
      n=0; for(k in seen) n++;
      printf "ts=%s; active_pools=%d; cl_active=%d; cl_waiting=%d; sv_active=%d; sv_idle=%d\n", ts, n, SUM_CA, SUM_CW, SUM_SA, SUM_SI;
    }' <<< "$pools"
}

assess() {
  local line="$1"
  local ts n_pools ca cw sa si
  ts=$(sed -E 's/.*ts=([^;]+).*/\1/' <<<"$line")
  n_pools=$(sed -E 's/.*active_pools=([0-9]+).*/\1/' <<<"$line")
  ca=$(sed -E 's/.*cl_active=([0-9]+).*/\1/' <<<"$line")
  cw=$(sed -E 's/.*cl_waiting=([0-9]+).*/\1/' <<<"$line")
  sa=$(sed -E 's/.*sv_active=([0-9]+).*/\1/' <<<"$line")
  si=$(sed -E 's/.*sv_idle=([0-9]+).*/\1/' <<<"$line")

  local used=0 util=0 used_raw
  if [[ "$PG_SHOW_USAGE" == "1" ]]; then
    used_raw=$(pg_current_used)
    if [[ "$used_raw" == ERR:* ]]; then
      used=0; util=0
    else
      used=$used_raw
      (( PG_BUDGET > 0 )) && util=$(( 100 * used / PG_BUDGET ))
    fi
  fi

  local per_pool=$(( DEFAULT_POOL + RESERVE_POOL ))
  local forecast=$(( n_pools * per_pool ))
  local status="OK"
  if (( forecast > PG_BUDGET )); then
    status="RISK: forecast > PG_BUDGET"
  elif (( forecast > PG_BUDGET * 90 / 100 )); then
    status="WARN: forecast near budget"
  fi

  printf "[%s] pools=%d  per_pool=%d  forecast=%d  PG_budget=%d  PG_used=%d(%d%%)  sv_active=%d sv_idle=%d  cl_waiting=%d  -> %s\n" \
    "$ts" "$n_pools" "$per_pool" "$forecast" "$PG_BUDGET" "$used" "$util" "$sa" "$si" "$cw" "$status"
}

main() {
  fetch_pgb_config
  fetch_pg_limits
  echo "# PgBouncer capacity guard"
  echo "# default_pool_size=${DEFAULT_POOL} reserve_pool_size=${RESERVE_POOL} ; PG max=${PG_MAX_CONNS} reserved=${PG_SUPER_RES} -> budget=${PG_BUDGET}"
  echo "# polling every ${INTERVAL}s ; filters: EXCL_DB=${EXCLUDE_DBS} EXCL_USER=${EXCLUDE_USERS} ; INCL_DB=${INCLUDE_DBS:-<none>} INCL_USER=${INCLUDE_USERS:-<none>}"
  echo
  while :; do
    line="$(snapshot)" || true
    [[ -n "${line:-}" ]] && assess "$line"
    if [[ "$ONESHOT" == "1" ]]; then break; fi
    sleep "$INTERVAL"
  done
}

main "$@"
