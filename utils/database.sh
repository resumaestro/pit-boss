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

  # Strip inline and full-line comments, then split on ; and send each statement
  # as a separate request so D1 commits schema changes between statements.
  local stripped_file stmt_file
  stripped_file=$(mktemp)
  stmt_file=$(mktemp)

  # Remove -- comments (inline and full-line) from each line
  sed 's/--.*$//' "$sql_file" > "$stripped_file"

  # Split on semicolons, trim whitespace, send each non-empty statement
  local buf=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    while [[ "$line" == *";"* ]]; do
      buf="${buf} ${line%%";"*}"
      buf="${buf#"${buf%%[![:space:]]*}"}"
      buf="${buf%"${buf##*[![:space:]]}"}"
      if [[ -n "$buf" ]]; then
        printf '%s' "$buf" > "$stmt_file"
        request_proxy_operation "$target" "exec" "$stmt_file" > /dev/null
      fi
      buf=""
      line="${line#*";"}"
    done
    buf="${buf} ${line}"
  done < "$stripped_file"

  buf="${buf#"${buf%%[![:space:]]*}"}"
  buf="${buf%"${buf##*[![:space:]]}"}"
  if [[ -n "$buf" ]]; then
    printf '%s' "$buf" > "$stmt_file"
    request_proxy_operation "$target" "exec" "$stmt_file" > /dev/null
  fi

  rm -f "$stripped_file" "$stmt_file"
}

execute_database_sql() {
  local target="$1"
  local sql="$2"
  local sql_file
  sql_file=$(mktemp)

  printf '%s\n' "$sql" > "$sql_file"

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
