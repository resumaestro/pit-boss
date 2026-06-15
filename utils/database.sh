#!/usr/bin/env bash
# Shared database transport through the Oboist proxy.

set -euo pipefail

validate_target() {
  local target="$1"
  if [[ -z "$target" ]]; then
    echo "ERROR: target is required." >&2
    return 1
  fi
}

validate_database_authentication() {
  if [[ -z "${PROXY_URL:-}" || -z "${PROXY_TOKEN:-}" ]]; then
    echo "ERROR: PROXY_URL and PROXY_TOKEN are required." >&2
    return 1
  fi
}

create_operation_payload() {
  local mode="$1"
  local sql_file="$2"

  jq -Rs \
    --arg mode "$mode" \
    '{ mode: $mode, sql: . }' \
    "$sql_file"
}

request_proxy_operation() {
  local target="$1"
  local mode="$2"
  local sql_file="$3"
  local response_file
  response_file=$(mktemp)

  if ! create_operation_payload "$mode" "$sql_file" \
    | curl \
      --silent \
      --show-error \
      --fail-with-body \
      --request POST \
      "${PROXY_URL%/}/operation/${target}" \
      --header "Authorization: Bearer ${PROXY_TOKEN}" \
      --header "Content-Type: application/json" \
      --data-binary @- \
      > "$response_file"; then
    cat "$response_file" >&2
    rm -f "$response_file"
    return 1
  fi

  cat "$response_file"
  rm -f "$response_file"
}

execute_database_file() {
  local target="$1"
  local sql_file="$2"
  local stmt_file
  stmt_file=$(mktemp)

  while IFS= read -r -d $'\0' stmt; do
    printf '%s' "$stmt" > "$stmt_file"
    if ! request_proxy_operation "$target" "exec" "$stmt_file" > /dev/null; then
      rm -f "$stmt_file"
      return 1
    fi
  done < <(python3 - "$sql_file" <<'PYEOF'
import sys, re
sql = open(sys.argv[1]).read()
lines = [re.sub(r'--.*$', '', line) for line in sql.splitlines()]
stmts = [s.strip() for s in ' '.join(lines).split(';') if s.strip()]
for stmt in stmts:
    sys.stdout.buffer.write(stmt.encode() + b'\x00')
PYEOF
  )

  rm -f "$stmt_file"
}

execute_database_sql() {
  local target="$1"
  local sql="$2"
  local sql_file
  sql_file=$(mktemp)

  printf '%s\n' "$sql" | tr '\n' ' ' > "$sql_file"

  if ! execute_database_file "$target" "$sql_file"; then
    rm -f "$sql_file"
    return 1
  fi

  rm -f "$sql_file"
}

query_database() {
  local target="$1"
  local sql="$2"
  local sql_file
  sql_file=$(mktemp)

  printf '%s\n' "$sql" > "$sql_file"

  if ! request_proxy_operation "$target" "query" "$sql_file" \
    | jq -e '.output'; then
    rm -f "$sql_file"
    return 1
  fi

  rm -f "$sql_file"
}

create_database_snapshot() {
  local target="$1"
  local output_file="$2"

  rm -f "$output_file"

  if ! jq -n '{}' \
    | curl \
      --silent \
      --show-error \
      --fail-with-body \
      --request POST \
      "${PROXY_URL%/}/snapshot/${target}" \
      --header "Authorization: Bearer ${PROXY_TOKEN}" \
      --header "Content-Type: application/json" \
      --data-binary @- \
      --output "$output_file"; then
    cat "$output_file" >&2
    rm -f "$output_file"
    return 1
  fi
}

restore_database_snapshot() {
  local target="$1"
  local snapshot_file="$2"

  execute_database_file "$target" "$snapshot_file"
}

ensure_database_exists() {
  local target="$1"

  query_database "$target" "SELECT 1 AS available;" > /dev/null
}
