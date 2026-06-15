#!/usr/bin/env bash
# Dry-run provision against target only.
# Always restores target to its pre-run state regardless of pass/fail.
# Used by PR checks to validate migrations and seeds before merge.

set -euo pipefail

PLAN_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../utils/database.sh
. "$PLAN_SCRIPT_DIR/../../utils/database.sh"

TARGET=""
PROVISION_DIR="provision"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)          TARGET="$2";        shift 2 ;;
    --provision-dir)   PROVISION_DIR="$2"; shift 2 ;;
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
  execute_database_sql "$TARGET" "
    CREATE TABLE IF NOT EXISTS schema_operations (
      kind       TEXT PRIMARY KEY,
      version    INTEGER NOT NULL,
      applied_at TEXT NOT NULL DEFAULT (datetime('now'))
    );" > /dev/null
}

read_version_local() {
  local kind="$1"
  query_database "$TARGET" \
    "SELECT COALESCE(version, 0) AS version FROM schema_operations WHERE kind = '$kind';" \
    | jq -er '.results[0].version // 0'
}

ensure_schema_operations_local

CURRENT_MIGRATION=$(read_version_local "migration")
CURRENT_SEED=$(read_version_local "seed")

TARGET_MIGRATION=0
if [[ -f "$CONFIG_FILE" ]]; then
  TARGET_MIGRATION=$(yq -r '.operation_versions.migration // 0' "$CONFIG_FILE")
else
  echo "No config.yml found at $CONFIG_FILE; skipping dry-run."
  exit 0
fi

if [[ -z "$TARGET_MIGRATION" || "$TARGET_MIGRATION" == "0" ]]; then
  echo "No operation_versions.migration in $CONFIG_FILE; skipping dry-run."
  exit 0
fi

echo "target migration=$CURRENT_MIGRATION seed=$CURRENT_SEED target=$TARGET_MIGRATION"

if [[ "$TARGET_MIGRATION" -eq "$CURRENT_MIGRATION" ]]; then
  echo "Target already at migration $TARGET_MIGRATION. Nothing to do."
  exit 0
fi

# shellcheck source=plan.sh
. "$PLAN_SCRIPT_DIR/plan.sh"

# ---- snapshot target before doing anything ---------------------------------

SNAP_FILE=$(mktemp)
echo ""
echo "==> Snapshotting target (will restore after regardless of result)..."
create_database_snapshot "$TARGET" "$SNAP_FILE"

PASSED=true

# ---- run the plan on target ------------------------------------------------

echo ""
echo "==> Running dry-run on target..."

SYSTEM_MIGRATION="$CURRENT_MIGRATION"

for seed_file in $(seeds_pending_at "$SYSTEM_MIGRATION"); do
  apply_seed "$TARGET" "$seed_file"
done

for (( v = CURRENT_MIGRATION + 1; v <= TARGET_MIGRATION; v++ )); do
  echo ""
  echo "  [$v] Testing up→down roundtrip..."

  snap_before=$(mktemp)
  snap_after=$(mktemp)
  create_database_snapshot "$TARGET" "$snap_before"

  apply_migration_up "$TARGET" "$v"
  apply_migration_down "$TARGET" "$v"

  create_database_snapshot "$TARGET" "$snap_after"

  if ! diff -q "$snap_before" "$snap_after" > /dev/null 2>&1; then
    rm -f "$snap_before" "$snap_after"
    echo "  [$v] ROUNDTRIP MISMATCH"
    PASSED=false
    break
  fi

  rm -f "$snap_before" "$snap_after"
  echo "  [$v] OK"

  apply_migration_up "$TARGET" "$v"
  SYSTEM_MIGRATION="$v"

  for seed_file in $(seeds_pending_at "$SYSTEM_MIGRATION"); do
    apply_seed "$TARGET" "$seed_file"
  done
done

# ---- always restore target -------------------------------------------------

echo ""
echo "==> Restoring target to pre-run state..."
restore_database_snapshot "$TARGET" "$SNAP_FILE" > /dev/null
rm -f "$SNAP_FILE"

if [[ "$PASSED" == "false" ]]; then
  echo "Dry-run FAILED."
  exit 2
fi

echo "Dry-run PASSED."
