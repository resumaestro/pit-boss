#!/usr/bin/env bash
# Apply migrations and seeds to a single target in the correct interleaved order.

set -euo pipefail

PLAN_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../utils/database.sh
. "$PLAN_SCRIPT_DIR/../../utils/database.sh"

TARGET=""
IS_PRODUCTION="false"
PROVISION_DIR="provision"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        TARGET="$2";        shift 2 ;;
    --is-production) IS_PRODUCTION="$2"; shift 2 ;;
    --provision-dir) PROVISION_DIR="$2"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "ERROR: --target is required" >&2
  exit 1
fi

CONFIG_FILE="$PROVISION_DIR/config.yml"
MIGRATIONS_DIR="$PROVISION_DIR/migrations"
SEEDS_DIR="$PROVISION_DIR/seeds"

validate_database_authentication

ensure_schema_operations_local() {
  local target="$1"
  execute_database_sql "$target" "
    CREATE TABLE IF NOT EXISTS schema_operations (
      kind       TEXT PRIMARY KEY,
      version    INTEGER NOT NULL,
      applied_at TEXT NOT NULL DEFAULT (datetime('now'))
    );" > /dev/null
}

read_version_local() {
  local target="$1" kind="$2"
  query_database "$target" \
    "SELECT COALESCE(version, 0) AS version FROM schema_operations WHERE kind = '$kind';" \
    | jq -er '.results[0].version // 0'
}

ensure_schema_operations_local "$TARGET"

CURRENT_MIGRATION=$(read_version_local "$TARGET" "migration")
CURRENT_SEED=$(read_version_local "$TARGET" "seed")

TARGET_MIGRATION=0
if [[ -f "$CONFIG_FILE" ]]; then
  TARGET_MIGRATION=$(yq -r '.operation_versions.migration // 0' "$CONFIG_FILE")
else
  echo "No config.yml found at $CONFIG_FILE; skipping provision."
  exit 0
fi

if [[ -z "$TARGET_MIGRATION" || "$TARGET_MIGRATION" == "0" ]]; then
  echo "No operation_versions.migration in $CONFIG_FILE; skipping provision."
  exit 0
fi

echo "$TARGET migration=$CURRENT_MIGRATION seed=$CURRENT_SEED target=$TARGET_MIGRATION"

if [[ "$TARGET_MIGRATION" -eq "$CURRENT_MIGRATION" ]]; then
  echo "Already at migration $TARGET_MIGRATION. Nothing to do."
  exit 0
fi

# shellcheck source=plan.sh
. "$PLAN_SCRIPT_DIR/plan.sh"

echo ""
echo "==> Applying to $TARGET (is_production=$IS_PRODUCTION)..."

CURRENT_V="$CURRENT_MIGRATION"

for seed_file in $(seeds_pending_at "$CURRENT_V"); do
  apply_seed "$TARGET" "$seed_file"
done

for (( v = CURRENT_MIGRATION + 1; v <= TARGET_MIGRATION; v++ )); do
  apply_migration_up "$TARGET" "$v"
  CURRENT_V="$v"

  for seed_file in $(seeds_pending_at "$CURRENT_V"); do
    apply_seed "$TARGET" "$seed_file"
  done
done

echo ""
echo "Done. $TARGET at migration=$TARGET_MIGRATION"
