#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMPORARY_DIR=$(mktemp -d)

cleanup_test_files() {
  rm -rf "$TEMPORARY_DIR"
}

trap cleanup_test_files EXIT

fail_test() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    fail_test "$message: expected '$expected', got '$actual'"
  fi
}

create_seed_file() {
  local path="$1"
  local minimum="$2"
  local maximum="$3"
  local sql="$4"

  {
    printf '%s\n' "-- pit-boss: MIGRATION_MIN=$minimum"
    printf '%s\n' "-- pit-boss: MIGRATION_MAX=$maximum"
    printf '\n%s\n' "$sql"
  } > "$path"
}

SEEDS_DIR="$TEMPORARY_DIR/seeds"
mkdir -p "$SEEDS_DIR"

create_seed_file \
  "$SEEDS_DIR/0001_initial.up.sql" \
  "1" \
  "3" \
  "INSERT INTO examples (name) VALUES ('initial');"
create_seed_file \
  "$SEEDS_DIR/0002_latest.up.sql" \
  "2" \
  "4" \
  "INSERT INTO examples (name) VALUES ('latest');"

# shellcheck source=../utils/seeds.sh
. "$ROOT_DIR/utils/seeds.sh"

selected_seed=$(select_seed_for_migration "3" "$SEEDS_DIR")
assert_equal \
  "$SEEDS_DIR/0002_latest.up.sql" \
  "$selected_seed" \
  "selector should choose the highest compatible seed version"

UNRESOLVED_DIR="$TEMPORARY_DIR/unresolved"
mkdir -p "$UNRESOLVED_DIR"
printf '%s\n' \
  "-- pit-boss: MIGRATION_MIN=1" \
  "INSERT INTO examples (name) VALUES ('unresolved');" \
  > "$UNRESOLVED_DIR/0001_unresolved.up.sql"

if select_seed_for_migration "1" "$UNRESOLVED_DIR" > /dev/null 2>&1; then
  fail_test "selector should reject unresolved MIGRATION_MAX annotations"
fi

CAPTURED_ARGUMENTS="$TEMPORARY_DIR/curl-arguments"
CAPTURED_PAYLOAD="$TEMPORARY_DIR/curl-payload"

CURL_CALL_COUNT_FILE="$TEMPORARY_DIR/curl-call-count"
printf '0' > "$CURL_CALL_COUNT_FILE"

curl() {
  local count
  count=$(cat "$CURL_CALL_COUNT_FILE")
  count=$(( count + 1 ))
  printf '%s' "$count" > "$CURL_CALL_COUNT_FILE"
  printf '%s\n' "$@" > "$CAPTURED_ARGUMENTS"
  if [[ "$count" -eq 2 ]]; then
    cat > "$CAPTURED_PAYLOAD"
  else
    cat > /dev/null
  fi
  printf '%s\n' '{"output":{"count":1}}'
}

export PROXY_TOKEN="test-secret"
export PROXY_URL="https://oboist.example"

(
  set -- \
    --target resumaestro-pipeline-sandbox \
    --migration-version 3 \
    --seeds "$SEEDS_DIR"
  # shellcheck source=../commands/apply-seed.sh
  . "$ROOT_DIR/commands/apply-seed.sh"
)

assert_equal \
  "exec" \
  "$(jq -r '.mode' "$CAPTURED_PAYLOAD")" \
  "seed application should use exec mode"

if ! jq -e '.sql | contains("VALUES ('\''latest'\'')")' "$CAPTURED_PAYLOAD" > /dev/null; then
  fail_test "seed application should send the selected seed SQL"
fi

if ! grep -Fx "https://oboist.example/resumaestro-pipeline-sandbox/operation" "$CAPTURED_ARGUMENTS" > /dev/null; then
  fail_test "transport should call the target operation endpoint"
fi

if ! grep -Fx "Authorization: Bearer test-secret" "$CAPTURED_ARGUMENTS" > /dev/null; then
  fail_test "transport should send the proxy token as bearer authorization"
fi

echo "seed tests passed"
