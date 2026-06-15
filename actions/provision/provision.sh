#!/usr/bin/env bash
# Apply migrations and seeds to production in the correct interleaved order.
# Optionally syncs a staging target to match after a successful production apply.

set -euo pipefail

PLAN_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../utils/database.sh
. "$PLAN_SCRIPT_DIR/../../utils/database.sh"

PRODUCTION_TARGET=""
STAGING_TARGET=""
PROVISION_DIR="provision"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --production-target) PRODUCTION_TARGET="$2"; shift 2 ;;
    --staging-target)    STAGING_TARGET="$2";    shift 2 ;;
    --provision-dir)     PROVISION_DIR="$2";     shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PRODUCTION_TARGET" ]]; then
  echo "ERROR: --production-target is required" >&2
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

ensure_schema_operations_local "$PRODUCTION_TARGET"

CURRENT_MIGRATION=$(read_version_local "$PRODUCTION_TARGET" "migration")
CURRENT_SEED=$(read_version_local "$PRODUCTION_TARGET" "seed")

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

echo "production migration=$CURRENT_MIGRATION seed=$CURRENT_SEED target=$TARGET_MIGRATION"

if [[ "$TARGET_MIGRATION" -eq "$CURRENT_MIGRATION" ]]; then
  echo "Already at migration $TARGET_MIGRATION. Nothing to do."
  exit 0
fi

# shellcheck source=plan.sh
. "$PLAN_SCRIPT_DIR/plan.sh"

# ---- apply to production ----------------------------------------------------

echo ""
echo "==> Applying to production..."

PROD_MIGRATION="$CURRENT_MIGRATION"

for seed_file in $(seeds_pending_at "$PROD_MIGRATION"); do
  apply_seed "$PRODUCTION_TARGET" "$seed_file"
done

for (( v = CURRENT_MIGRATION + 1; v <= TARGET_MIGRATION; v++ )); do
  apply_migration_up "$PRODUCTION_TARGET" "$v"
  PROD_MIGRATION="$v"

  for seed_file in $(seeds_pending_at "$PROD_MIGRATION"); do
    apply_seed "$PRODUCTION_TARGET" "$seed_file"
  done
done

echo ""
echo "Done. Production at migration=$TARGET_MIGRATION"

# ---- sync staging to match --------------------------------------------------

if [[ -n "$STAGING_TARGET" ]]; then
  echo ""
  echo "==> Syncing staging to match production..."

  ensure_schema_operations_local "$STAGING_TARGET"

  STAGING_MIGRATION=$(read_version_local "$STAGING_TARGET" "migration")
  STAGING_SEED=$(read_version_local "$STAGING_TARGET" "seed")

  CURRENT_MIGRATION="$STAGING_MIGRATION"
  CURRENT_SEED="$STAGING_SEED"

  unset PENDING_SEED_FILES PENDING_SEED_AT
  # shellcheck source=plan.sh
  . "$PLAN_SCRIPT_DIR/plan.sh"

  SB_MIGRATION="$STAGING_MIGRATION"

  for seed_file in $(seeds_pending_at "$SB_MIGRATION"); do
    apply_seed "$STAGING_TARGET" "$seed_file"
  done

  for (( v = STAGING_MIGRATION + 1; v <= TARGET_MIGRATION; v++ )); do
    apply_migration_up "$STAGING_TARGET" "$v"
    SB_MIGRATION="$v"

    for seed_file in $(seeds_pending_at "$SB_MIGRATION"); do
      apply_seed "$STAGING_TARGET" "$seed_file"
    done
  done

  echo "Staging synced to migration=$TARGET_MIGRATION"
fi
