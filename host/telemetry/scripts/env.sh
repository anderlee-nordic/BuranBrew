#!/usr/bin/env bash
# Shared telemetry environment loader.
#
# The telemetry scripts run from immutable Nix store paths, so they cannot
# find ../host.env relative to themselves. Prefer BURANBREW_HOST_ENV when set,
# otherwise use ./host.env from the directory where the user launched the stack.
#
# shellcheck shell=bash

_trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

_unquote_value() {
  local value="$1"
  if [ "${#value}" -ge 2 ]; then
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
  fi
  printf '%s' "$value"
}

_load_telemetry_ports() {
  local file="$1"
  local line key value

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="$(_trim_space "$line")"
    case "$line" in
      ''|'#'*) continue ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"
    [ "$key" != "$line" ] || continue
    key="$(_trim_space "$key")"

    case "$key" in
      REDIS_PORT|POSTGRES_PORT|GRAFANA_PORT) ;;
      *) continue ;;
    esac

    value="${value%%#*}"
    value="$(_trim_space "$value")"
    value="$(_unquote_value "$value")"

    # A port should be a plain decimal number. Ignore malformed values so 
    # it can safely fall back to the original defaults below.
    case "$value" in
      ''|*[!0-9]*) continue ;;
    esac

    if [ -z "${!key+x}" ]; then
      export "$key=$value"
    fi
  done < "$file"
}

if [ -n "${BURANBREW_HOST_ENV:-}" ]; then
  _load_telemetry_ports "$BURANBREW_HOST_ENV"
elif [ -f "$PWD/host.env" ]; then
  _load_telemetry_ports "$PWD/host.env"
fi

export REDIS_PORT="${REDIS_PORT:-6379}"
export POSTGRES_PORT="${POSTGRES_PORT:-5433}"
export GRAFANA_PORT="${GRAFANA_PORT:-3000}"

export REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:${REDIS_PORT}}"
export PG_DSN="${PG_DSN:-postgres://buranbrew@127.0.0.1:${POSTGRES_PORT}/buranbrew?sslmode=disable}"
