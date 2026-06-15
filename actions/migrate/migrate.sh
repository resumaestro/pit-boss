#!/usr/bin/env bash
# Reusable migration reconciler with staging roundtrip testing.
#
# Usage:
#   ./migrate.sh --production-target <name> --config <path> --snaps <path> [--staging-target <name>] [--migrations <path>]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../../utils/database.sh
. "$SCRIPT_DIR/../../utils/database.sh"

PRODUCTION_TARGET=""
STAGING_TARGET=""
CONFIG_FILE=""
MIGRATIONS_DIR="provision/migrations"
SNAPS_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --production-target) PRODUCTION_TARGET="$2"; shift 2 ;;
    --staging-target)    STAGING_TARGET="$2";    shift 2 ;;
    --config)            CONFIG_FILE="$2";        shift 2 ;;
    --migrations)        MIGRATIONS_DIR="$2";     shift 2 ;;
    --snaps)             SNAPS_DIR="$2";          shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

for required_variable in PRODUCTION_TARGET CONFIG_FILE SNAPS_DIR; do
  if [[ -z "${!required_variable}" ]]; then
    echo "ERROR: --$(echo "$required_variable" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required" >&2
    exit 1
  fi
done

validate_database_authentication

if [[ -z "$STAGING_TARGET" ]]; then
  STAGING_TARGET="${PRODUCTION_TARGET}-staging"
  echo "No --staging-target specified; defaulting to '$STAGING_TARGET'"
fi

mkdir -p "$SNAPS_DIR"

# ---- helpers ----------------------------------------------------------------

create_snapshot_file_path() {
  printf "%s/snap_%04d.sql" "$SNAPS_DIR" "$1"
}

create_snapshot() {
  local target="$1"
  local version="$2"
  local file
  file=$(create_snapshot_file_path "$version")
  echo "  Exporting $target as snap_$(printf '%04d' "$version").sql..."
  create_database_snapshot "$target" "$file"
}

restore_snapshot() {
  local target="$1"
  local version="$2"
  local file
  file=$(create_snapshot_file_path "$version")
  echo "  Restoring $target from snap_$(printf '%04d' "$version").sql..."
  restore_database_snapshot "$target" "$file" > /dev/null
}

find_migration() {
  local version="$1"
  local direction="$2"
  local padded
  padded=$(printf "%04d" "$version")
  ls "$MIGRATIONS_DIR"/${padded}_*.${direction}.sql 2>/dev/null | head -1 || true
}

ensure_migrations_table() {
  local target="$1"
  execute_database_sql "$target" "
    CREATE TABLE IF NOT EXISTS schema_operations (
      kind        TEXT PRIMARY KEY,
      version     INTEGER NOT NULL,
      applied_at  TEXT NOT NULL DEFAULT (datetime('now'))
    );
  " > /dev/null
}

read_applied_version() {
  local target="$1"
  query_database "$target" \
    "SELECT COALESCE(version, 0) AS version FROM schema_operations WHERE kind = 'migration';" \
    | jq -er '.results[0].version // 0'
}

apply_migration_up() {
  local target="$1"
  local version="$2"
  local file
  file=$(find_migration "$version" "up")
  if [[ -z "$file" ]]; then
    echo "ERROR: no up file for version $version" >&2
    exit 1
  fi
  execute_database_file "$target" "$file" > /dev/null
  execute_database_sql "$target" \
    "INSERT INTO schema_operations (kind, version) VALUES ('migration', $version)
     ON CONFLICT(kind) DO UPDATE SET version = excluded.version, applied_at = datetime('now');" > /dev/null
}

apply_migration_down() {
  local target="$1"
  local version="$2"
  local file
  file=$(find_migration "$version" "down")
  if [[ -z "$file" ]]; then
    echo "ERROR: no down file for version $version" >&2
    exit 1
  fi
  execute_database_file "$target" "$file" > /dev/null
  execute_database_sql "$target" \
    "INSERT INTO schema_operations (kind, version) VALUES ('migration', $((version - 1)))
     ON CONFLICT(kind) DO UPDATE SET version = excluded.version, applied_at = datetime('now');" > /dev/null
}

# ---- read versions ----------------------------------------------------------

TARGET=$(yq -r '.operation_versions.migration' "$CONFIG_FILE")
ensure_migrations_table "$PRODUCTION_TARGET"
ensure_migrations_table "$STAGING_TARGET"
ACTUAL=$(read_applied_version "$PRODUCTION_TARGET")

echo "actual=$ACTUAL target=$TARGET"

if [[ "$TARGET" -eq "$ACTUAL" ]]; then
  echo "Already at version $TARGET. Nothing to do."
  exit 0
fi

if [[ ! -d "$MIGRATIONS_DIR" ]] || [[ -z "$(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null)" ]]; then
  echo "WARNING: migrations dir '$MIGRATIONS_DIR' is missing or empty — skipping migration."
  exit 0
fi

ACTUAL_SNAP=$(create_snapshot_file_path "$ACTUAL")
if [[ ! -f "$ACTUAL_SNAP" ]]; then
  create_snapshot "$STAGING_TARGET" "$ACTUAL"
fi

# ---- up ---------------------------------------------------------------------

if [[ "$TARGET" -gt "$ACTUAL" ]]; then
  echo ""
  echo "==> Dry-run: testing migrations $((ACTUAL + 1))..$TARGET on staging..."

  FAILED=false
  for ((v = ACTUAL + 1; v <= TARGET; v++)); do
    echo ""
    echo "  [$v] Testing up→down roundtrip..."

    snap_before_file=$(mktemp)
    snap_after_file=$(mktemp)
    create_database_snapshot "$STAGING_TARGET" "$snap_before_file"

    apply_migration_up "$STAGING_TARGET" "$v"
    apply_migration_down "$STAGING_TARGET" "$v"

    create_database_snapshot "$STAGING_TARGET" "$snap_after_file"

    if ! diff -q "$snap_before_file" "$snap_after_file" > /dev/null 2>&1; then
      rm -f "$snap_before_file" "$snap_after_file"
      echo "  [$v] ROUNDTRIP MISMATCH"
      FAILED=true
      break
    fi

    rm -f "$snap_before_file" "$snap_after_file"
    echo "  [$v] OK"
    apply_migration_up "$STAGING_TARGET" "$v"
  done

  if [[ "$FAILED" == "true" ]]; then
    echo ""
    echo "Dry-run failed. Restoring staging..."
    restore_snapshot "$STAGING_TARGET" "$ACTUAL"
    exit 2
  fi

  echo ""
  echo "==> Applying migrations $((ACTUAL + 1))..$TARGET to production..."
  for ((v = ACTUAL + 1; v <= TARGET; v++)); do
    echo "  Applying $v..."
    apply_migration_up "$PRODUCTION_TARGET" "$v"
  done

  create_snapshot "$STAGING_TARGET" "$TARGET"
  echo ""
  echo "Done. Production is now at version $TARGET."
fi

# ---- down -------------------------------------------------------------------

if [[ "$TARGET" -lt "$ACTUAL" ]]; then
  echo ""
  echo "==> Dry-run: testing rollback $ACTUAL→$TARGET on staging..."

  FAILED=false
  for ((v = ACTUAL; v > TARGET; v--)); do
    echo "  [$v] Applying down on staging..."
    if ! apply_migration_down "$STAGING_TARGET" "$v"; then
      FAILED=true
      break
    fi
  done

  if [[ "$FAILED" == "true" ]]; then
    echo ""
    echo "Dry-run failed. Restoring staging..."
    restore_snapshot "$STAGING_TARGET" "$ACTUAL"
    exit 2
  fi

  create_snapshot "$STAGING_TARGET" "$TARGET"

  echo ""
  echo "==> Applying rollback $ACTUAL→$TARGET to production..."
  for ((v = ACTUAL; v > TARGET; v--)); do
    echo "  Rolling back $v..."
    apply_migration_down "$PRODUCTION_TARGET" "$v"
  done

  echo ""
  echo "Done. Production is now at version $TARGET."
fi
