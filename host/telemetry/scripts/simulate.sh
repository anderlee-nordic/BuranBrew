#!/usr/bin/env bash
# This script is AI-generated, used for testing purpose only. It can:
#   Generates synthetic telemetry to run end-to-end Grafana alert demo,
#   or validates alert SQL predicates inside rollback-only test transactions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
R=(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT")

usage() {
  cat <<'USAGE'
Cellarman telemetry simulator and alert helper

Usage:
  cellarman-simulate [period_seconds]
  cellarman-simulate live [period_seconds]
  cellarman-simulate alert-test [case]
  cellarman-simulate alert-demo [scenario] [period_seconds]

Direct script form is also supported:
  telemetry/scripts/simulate.sh ...

Modes:
  live [period_seconds]
      Emit healthy synthetic telemetry to Redis every N seconds.
      Default period: 2 seconds.
      Shortcut: passing only a number is the same as live, for example:
        cellarman-simulate 1

  alert-test [case]
      Fast SQL-only validation of the provisioned alert predicates.
      This writes temporary rows inside one transaction, checks the alert logic,
      then rolls back. Historical telemetry is not changed.

      Cases:
        all                 run every case, default
        healthy             no alert should fire
        stale-all           sensor and control telemetry are older than 180s
        danger-temp         internal temperature is outside 5..30 C
        sg-jump             latest two fresh SG readings differ by > 0.005
        ineffective-heat    HEAT has run for >2h without IDLE
        ineffective-cool    COOL has run for >2h without IDLE
        empty               no telemetry exists, stale rules should fire

      Use alert-test when you want a quick deterministic check. It validates
      the SQL thresholds, not Grafana's scheduler, notification path, or hold
      timer behavior.

  alert-demo [scenario] [period_seconds]
      End-to-end demo through the real telemetry path:
        Redis streams -> Go consumer -> TimescaleDB -> Grafana alerts

      This emits real Redis telemetry and therefore creates real TimescaleDB
      rows. Stop it with Ctrl-C when the demo is done.

      Scenarios:
        healthy             normal ambient/internal/gravity/control telemetry
        stale-sensors       stop ambient, internal, and gravity telemetry
        stale-control       stop control-loop telemetry
        stale-ambient       stop only ambient telemetry
        stale-internal      stop only internal temperature telemetry
        stale-gravity       stop only gravity telemetry
        stale-all           stop all sensor and control telemetry
        dangerous-temp-high emit internal temperature above 30 C
        dangerous-temp-low  emit internal temperature below 5 C
        sg-jump             alternate gravity values to create a >0.005 jump
        ineffective-heat    emit continuous HEAT actions
        ineffective-cool    emit continuous COOL actions

Alert rule summary:
  - ambient/internal/gravity/control stale: latest row age > 180 seconds
  - dangerous internal temperature: latest fresh internal value < 5 C or > 30 C
  - SG jump: latest two fresh gravity readings differ by more than 0.005
  - controller ineffective: HEAT or COOL active for more than 2h with no IDLE

Grafana timing notes:
  - Grafana evaluates these rules every 60 seconds.
  - Stale and dangerous-temperature demos need about 5 minutes to show firing:
    3 minute threshold plus 2 minute hold.
  - SG-jump and controller-ineffective rules have no extra Grafana hold.
  - ineffective-heat and ineffective-cool still need more than 2 hours of
    continuous HEAT/COOL in the end-to-end demo. Use alert-test for a fast check.

Environment:
  Ports are loaded from host.env when run through nix from the host directory:
    REDIS_PORT=6379
    POSTGRES_PORT=5433
    GRAFANA_PORT=3000

  These can also be overridden in the shell. Examples:
    REDIS_PORT=6380 cellarman-simulate live 1
    POSTGRES_PORT=5544 cellarman-simulate alert-test all

Examples:
  nix run .#cellarman-simulate -- live 1
  nix run .#cellarman-simulate -- alert-test all
  nix run .#cellarman-simulate -- alert-test sg-jump
  nix run .#cellarman-simulate -- alert-demo dangerous-temp-high 2
  nix run .#cellarman-simulate -- alert-demo stale-control 2

Typical workflow:
  1. Start the stack: nix run .#cellarman
  2. In another shell, run a simulator command from above.
  3. Open Grafana and watch Cellarman dashboard / alert state.
USAGE
}
emit_sensor() {
  local ts_ms="$1" metric="$2" value="$3"
  "${R[@]}" xadd telemetry:sensor 'MAXLEN' '~' 100000 '*' \
    ts_ms "$ts_ms" node 1 metric "$metric" value "$value" > /dev/null
}

emit_control() {
  local ts_ms="$1" action="$2" diff="$3" source="${4:-simulator}"
  "${R[@]}" xadd telemetry:control 'MAXLEN' '~' 100000 '*' \
    ts_ms "$ts_ms" action "$action" diff_centi "$diff" source "$source" > /dev/null
}

should_emit_metric() {
  local scenario="$1" metric="$2"
  case "$scenario:$metric" in
    stale-all:*|stale-sensors:*|stale-ambient:ambient|stale-internal:internal|stale-gravity:gravity)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

should_emit_control() {
  local scenario="$1"
  case "$scenario" in
    stale-all|stale-control)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

run_generator() {
  local scenario="$1" period="$2"
  local i=0

  case "$scenario" in
    healthy|stale-sensors|stale-control|stale-ambient|stale-internal|stale-gravity|stale-all|dangerous-temp-high|dangerous-temp-low|sg-jump|ineffective-heat|ineffective-cool) ;;
    *)
      echo "unknown simulator scenario: $scenario" >&2
      usage >&2
      exit 2
      ;;
  esac

  if [ "$scenario" = healthy ]; then
    echo "simulating: sensor sine waves + banded control decisions every ${period}s"
  else
    echo "simulating alert demo: scenario=${scenario}, period=${period}s"
    echo "note: Grafana rules evaluate every 60s; stale rules require 3m stale + 2m hold"
    if [[ "$scenario" == ineffective-* ]]; then
      echo "note: ineffective-controller demos intentionally need >2h of continuous HEAT/COOL; use alert-test for a fast deterministic check"
    fi
  fi

  while true; do
    i=$((i+1))
    local ambient internal sg diff action ts emitted=()
    ambient=$(awk -v i="$i" 'BEGIN{printf "%.2f", 21 + 2.5*sin(i/40)}')
    internal=$(awk -v i="$i" 'BEGIN{printf "%.2f", 21 + 4.0*sin(i/25 + 1.3)}')
    sg=$(awk -v i="$i" 'BEGIN{printf "%.4f", 1.060 - 0.048*(1-exp(-i/900))}')

    case "$scenario" in
      dangerous-temp-high) internal="31.50" ;;
      dangerous-temp-low)  internal="4.00" ;;
      sg-jump)
        if [ $((i % 2)) -eq 0 ]; then sg="1.0600"; else sg="1.0500"; fi
        ;;
    esac

    diff=$(awk -v a="$ambient" -v b="$internal" 'BEGIN{printf "%d", (b-a)*100}')
    if   [ "$diff" -gt  200 ]; then action=COOL
    elif [ "$diff" -lt -200 ]; then action=HEAT
    else                            action=IDLE; fi

    case "$scenario" in
      ineffective-heat) action=HEAT; diff=-250 ;;
      ineffective-cool) action=COOL; diff=250 ;;
    esac

    ts=$(date +%s%3N)

    if should_emit_metric "$scenario" ambient; then
      emit_sensor "$ts" ambient "$ambient"
      emitted+=("ambient=$ambient")
    fi
    if should_emit_metric "$scenario" internal; then
      emit_sensor "$ts" internal "$internal"
      emitted+=("internal=$internal")
    fi
    if should_emit_metric "$scenario" gravity; then
      emit_sensor "$ts" gravity "$sg"
      emitted+=("SG=$sg")
    fi
    if should_emit_control "$scenario"; then
      emit_control "$ts" "$action" "$diff"
      emitted+=("action=$action")
    fi

    "${R[@]}" hset telemetry:state ambient "$ambient" internal "$internal" \
      sg "$sg" action "$action" updated_ms "$ts" scenario "$scenario" > /dev/null

    if [ "${#emitted[@]}" -eq 0 ]; then
      echo "[sim:${scenario}] emitted nothing; all existing series are aging"
    else
      echo "[sim:${scenario}] ${emitted[*]}"
    fi
    sleep "$period"
  done
}

psql_scalar() {
  if ! command -v psql >/dev/null 2>&1; then
    echo "psql not found. Run via nix run .#cellarman-simulate -- alert-test, or add psql to PATH." >&2
    exit 127
  fi
  psql -X -qAt -v ON_ERROR_STOP=1 "$PG_DSN" "$@"
}

run_alert_case() {
  local name="$1" seed_sql="$2"
  local exp_ambient="$3" exp_internal="$4" exp_gravity="$5" exp_control="$6"
  local exp_temp="$7" exp_sg="$8" exp_ineffective="$9"
  local out status details

  out=$(psql_scalar <<SQL
BEGIN;
TRUNCATE sensor_data, control_events;
${seed_sql}
WITH latest_sensor AS (
  SELECT DISTINCT ON (metric) metric, value, ts
  FROM sensor_data
  WHERE metric IN ('ambient', 'internal', 'gravity')
  ORDER BY metric, ts DESC
), last_two_gravity AS (
  SELECT row_number() OVER (ORDER BY ts DESC) AS rn, ts, value
  FROM sensor_data
  WHERE metric = 'gravity'
  ORDER BY ts DESC
  LIMIT 2
), gravity_pair AS (
  SELECT
    max(value) FILTER (WHERE rn = 1) AS current_sg,
    max(value) FILTER (WHERE rn = 2) AS previous_sg,
    max(ts) FILTER (WHERE rn = 1) AS current_ts,
    max(ts) FILTER (WHERE rn = 2) AS previous_ts
  FROM last_two_gravity
), control_calc AS (
  SELECT
    (SELECT action FROM control_events ORDER BY ts DESC LIMIT 1) AS action,
    (SELECT ts FROM control_events ORDER BY ts DESC LIMIT 1) AS latest_ts
), conditions(rule, actual_alert, expected_alert, detail) AS (
  VALUES
    (
      'ambient-stale',
      coalesce(extract(epoch FROM now() - (SELECT ts FROM latest_sensor WHERE metric = 'ambient')), 1000000000) > 180,
      ${exp_ambient}::boolean,
      'age_s=' || round(coalesce(extract(epoch FROM now() - (SELECT ts FROM latest_sensor WHERE metric = 'ambient')), 1000000000))::text
    ),
    (
      'internal-stale',
      coalesce(extract(epoch FROM now() - (SELECT ts FROM latest_sensor WHERE metric = 'internal')), 1000000000) > 180,
      ${exp_internal}::boolean,
      'age_s=' || round(coalesce(extract(epoch FROM now() - (SELECT ts FROM latest_sensor WHERE metric = 'internal')), 1000000000))::text
    ),
    (
      'gravity-stale',
      coalesce(extract(epoch FROM now() - (SELECT ts FROM latest_sensor WHERE metric = 'gravity')), 1000000000) > 180,
      ${exp_gravity}::boolean,
      'age_s=' || round(coalesce(extract(epoch FROM now() - (SELECT ts FROM latest_sensor WHERE metric = 'gravity')), 1000000000))::text
    ),
    (
      'control-stale',
      coalesce(extract(epoch FROM now() - (SELECT ts FROM control_events ORDER BY ts DESC LIMIT 1)), 1000000000) > 180,
      ${exp_control}::boolean,
      'age_s=' || round(coalesce(extract(epoch FROM now() - (SELECT ts FROM control_events ORDER BY ts DESC LIMIT 1)), 1000000000))::text
    ),
    (
      'danger-temp',
      EXISTS (
        SELECT 1
        FROM latest_sensor
        WHERE metric = 'internal'
          AND ts > now() - interval '3 minutes'
          AND (value < 5.0 OR value > 30.0)
      ),
      ${exp_temp}::boolean,
      'internal=' || coalesce((SELECT value::text FROM latest_sensor WHERE metric = 'internal'), 'NULL')
    ),
    (
      'sg-jump',
      EXISTS (
        SELECT 1
        FROM gravity_pair
        WHERE current_ts > now() - interval '3 minutes'
          AND previous_ts > now() - interval '1 hour'
          AND abs(current_sg - previous_sg) > 0.005
      ),
      ${exp_sg}::boolean,
      'jump=' || coalesce((SELECT round(abs(current_sg - previous_sg)::numeric, 4)::text FROM gravity_pair), 'NULL')
    ),
    (
      'controller-ineffective',
      EXISTS (
        SELECT 1
        FROM control_calc
        WHERE action IN ('HEAT', 'COOL')
          AND latest_ts > now() - interval '3 minutes'
          AND NOT EXISTS (
            SELECT 1
            FROM control_events
            WHERE action = 'IDLE'
              AND ts > now() - interval '2 hours'
              AND ts <= latest_ts
          )
          AND extract(epoch FROM now() - coalesce(
            (SELECT min(ts)
             FROM control_events
             WHERE action IN ('HEAT', 'COOL')
               AND ts > now() - interval '3 hours'),
            latest_ts
          )) > 7200
      ),
      ${exp_ineffective}::boolean,
      'action=' || coalesce((SELECT action FROM control_calc), 'NULL')
    )
)
SELECT
  CASE WHEN bool_and(actual_alert = expected_alert) THEN 'PASS' ELSE 'FAIL' END
  || '|' || string_agg(
    rule || ':actual=' || actual_alert || ',expected=' || expected_alert || ',' || detail,
    '; ' ORDER BY rule
  )
FROM conditions;
ROLLBACK;
SQL
  )

  status="${out%%|*}"
  details="${out#*|}"
  printf '[alert-test] %-18s %s\n' "$name" "$status"
  printf '             %s\n' "$details"
  [ "$status" = PASS ]
}

run_alert_tests() {
  local selected="${1:-all}" failed=0
  local fresh="now() - interval '10 seconds'"
  local stale="now() - interval '185 seconds'"
  local old_active="now() - interval '121 minutes'"
  local mid_active="now() - interval '60 minutes'"

  case "$selected" in
    all|healthy|stale-all|danger-temp|sg-jump|ineffective-heat|ineffective-cool|empty) ;;
    *)
      echo "unknown alert-test case: $selected" >&2
      usage >&2
      exit 2
      ;;
  esac

  echo "testing alert SQL conditions against: $PG_DSN"
  echo "note: this validates threshold predicates, not Grafana's alert engine or 2m 'for' timer"

  if [ "$selected" = all ] || [ "$selected" = healthy ]; then
    run_alert_case healthy "
      INSERT INTO sensor_data (ts, node_id, metric, value, event_id) VALUES
        (${fresh}, 1, 'ambient', 21.0, 'alert-test-healthy-ambient'),
        (${fresh}, 1, 'internal', 20.5, 'alert-test-healthy-internal'),
        (${fresh}, 1, 'gravity', 1.050, 'alert-test-healthy-gravity-a'),
        (now() - interval '70 seconds', 1, 'gravity', 1.051, 'alert-test-healthy-gravity-b');
      INSERT INTO control_events (ts, action, diff_centi, detail, event_id) VALUES
        (${fresh}, 'IDLE', 0, '{}'::jsonb, 'alert-test-healthy-control');
    " false false false false false false false || failed=1
  fi

  if [ "$selected" = all ] || [ "$selected" = stale-all ]; then
    run_alert_case stale-all "
      INSERT INTO sensor_data (ts, node_id, metric, value, event_id) VALUES
        (${stale}, 1, 'ambient', 21.0, 'alert-test-stale-ambient'),
        (${stale}, 1, 'internal', 20.5, 'alert-test-stale-internal'),
        (${stale}, 1, 'gravity', 1.050, 'alert-test-stale-gravity');
      INSERT INTO control_events (ts, action, diff_centi, detail, event_id) VALUES
        (${stale}, 'IDLE', 0, '{}'::jsonb, 'alert-test-stale-control');
    " true true true true false false false || failed=1
  fi

  if [ "$selected" = all ] || [ "$selected" = danger-temp ]; then
    run_alert_case danger-temp "
      INSERT INTO sensor_data (ts, node_id, metric, value, event_id) VALUES
        (${fresh}, 1, 'ambient', 21.0, 'alert-test-temp-ambient'),
        (${fresh}, 1, 'internal', 31.5, 'alert-test-temp-internal'),
        (${fresh}, 1, 'gravity', 1.050, 'alert-test-temp-gravity-a'),
        (now() - interval '70 seconds', 1, 'gravity', 1.051, 'alert-test-temp-gravity-b');
      INSERT INTO control_events (ts, action, diff_centi, detail, event_id) VALUES
        (${fresh}, 'IDLE', 0, '{}'::jsonb, 'alert-test-temp-control');
    " false false false false true false false || failed=1
  fi

  if [ "$selected" = all ] || [ "$selected" = sg-jump ]; then
    run_alert_case sg-jump "
      INSERT INTO sensor_data (ts, node_id, metric, value, event_id) VALUES
        (${fresh}, 1, 'ambient', 21.0, 'alert-test-sg-ambient'),
        (${fresh}, 1, 'internal', 20.5, 'alert-test-sg-internal'),
        (now() - interval '70 seconds', 1, 'gravity', 1.050, 'alert-test-sg-gravity-prev'),
        (${fresh}, 1, 'gravity', 1.060, 'alert-test-sg-gravity-current');
      INSERT INTO control_events (ts, action, diff_centi, detail, event_id) VALUES
        (${fresh}, 'IDLE', 0, '{}'::jsonb, 'alert-test-sg-control');
    " false false false false false true false || failed=1
  fi

  if [ "$selected" = all ] || [ "$selected" = ineffective-heat ]; then
    run_alert_case ineffective-heat "
      INSERT INTO sensor_data (ts, node_id, metric, value, event_id) VALUES
        (${fresh}, 1, 'ambient', 21.0, 'alert-test-heat-ambient'),
        (${fresh}, 1, 'internal', 20.5, 'alert-test-heat-internal'),
        (${fresh}, 1, 'gravity', 1.050, 'alert-test-heat-gravity-a'),
        (now() - interval '70 seconds', 1, 'gravity', 1.051, 'alert-test-heat-gravity-b');
      INSERT INTO control_events (ts, action, diff_centi, detail, event_id) VALUES
        (${old_active}, 'HEAT', -250, '{}'::jsonb, 'alert-test-heat-old'),
        (${mid_active}, 'HEAT', -250, '{}'::jsonb, 'alert-test-heat-mid'),
        (${fresh}, 'HEAT', -250, '{}'::jsonb, 'alert-test-heat-current');
    " false false false false false false true || failed=1
  fi

  if [ "$selected" = all ] || [ "$selected" = ineffective-cool ]; then
    run_alert_case ineffective-cool "
      INSERT INTO sensor_data (ts, node_id, metric, value, event_id) VALUES
        (${fresh}, 1, 'ambient', 21.0, 'alert-test-cool-ambient'),
        (${fresh}, 1, 'internal', 20.5, 'alert-test-cool-internal'),
        (${fresh}, 1, 'gravity', 1.050, 'alert-test-cool-gravity-a'),
        (now() - interval '70 seconds', 1, 'gravity', 1.051, 'alert-test-cool-gravity-b');
      INSERT INTO control_events (ts, action, diff_centi, detail, event_id) VALUES
        (${old_active}, 'COOL', 250, '{}'::jsonb, 'alert-test-cool-old'),
        (${mid_active}, 'COOL', 250, '{}'::jsonb, 'alert-test-cool-mid'),
        (${fresh}, 'COOL', 250, '{}'::jsonb, 'alert-test-cool-current');
    " false false false false false false true || failed=1
  fi

  if [ "$selected" = all ] || [ "$selected" = empty ]; then
    run_alert_case empty "" true true true true false false false || failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    echo "alert SQL condition tests failed" >&2
    exit 1
  fi
  echo "all selected alert SQL condition tests passed"
}

main() {
  local mode="${1:-live}"

  # Backward compatibility: simulate.sh 2
  if [[ "$mode" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    run_generator healthy "$mode"
    return
  fi

  case "$mode" in
    live)
      run_generator healthy "${2:-2}"
      ;;
    alert-demo)
      run_generator "${2:-healthy}" "${3:-2}"
      ;;
    alert-test)
      run_alert_tests "${2:-all}"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "unknown mode: $mode" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
