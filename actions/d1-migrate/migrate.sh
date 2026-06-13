#!/usr/bin/env bash
# Reusable D1 migration reconciler.
#
# Usage:
#   ./migrate.sh --db <name> --sandbox-db <name> --config <path> --migrations <path> --snaps <path> [--remote]

set -euo pipefail

DB_NAME=""
SANDBOX_DB_NAME=""
CONFIG_FILE=""
MIGRATIONS_DIR=""
SNAPS_DIR=""
REMOTE_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)           DB_NAME="$2";        shift 2 ;;
    --sandbox-db)   SANDBOX_DB_NAME="$2"; shift 2 ;;
    --config)       CONFIG_FILE="$2";    shift 2 ;;
    --migrations)   MIGRATIONS_DIR="$2"; shift 2 ;;
    --snaps)        SNAPS_DIR="$2";      shift 2 ;;
    --remote)       REMOTE_FLAG="--remote"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

for var in DB_NAME SANDBOX_DB_NAME CONFIG_FILE MIGRATIONS_DIR SNAPS_DIR; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: --$(echo "$var" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required"
    exit 1
  fi
done

mkdir -p "$SNAPS_DIR"

# ---- helpers ----------------------------------------------------------------

d1() {
  local db="$1"; shift
  npx wrangler d1 execute "$db" $REMOTE_FLAG "$@" > /dev/null
}

d1_json() {
  local db="$1"; shift
  npx wrangler d1 execute "$db" $REMOTE_FLAG --json "$@"
}

snap_file() {
  printf "%s/snap_%04d.sql" "$SNAPS_DIR" "$1"
}

export_snap() {
  local db="$1"
  local version="$2"
  local file
  file=$(snap_file "$version")
  echo "  Exporting $db as snap_$(printf '%04d' "$version").sql..."
  npx wrangler d1 export "$db" $REMOTE_FLAG --output="$file"
}

restore_snap() {
  local db="$1"
  local version="$2"
  local file
  file=$(snap_file "$version")
  echo "  Restoring $db from snap_$(printf '%04d' "$version").sql..."
  npx wrangler d1 execute "$db" $REMOTE_FLAG --file="$file" > /dev/null
}

find_migration_file() {
  local version="$1"
  local direction="$2"
  local padded
  padded=$(printf "%04d" "$version")
  ls "$MIGRATIONS_DIR"/${padded}_*.${direction}.sql 2>/dev/null | head -1
}

ensure_migrations_table() {
  local db="$1"
  d1 "$db" --command "
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version     INTEGER PRIMARY KEY,
      applied_at  TEXT NOT NULL DEFAULT (datetime('now'))
    );
  "
}

get_applied_version() {
  local db="$1"
  d1_json "$db" --command "SELECT COALESCE(MAX(version), 0) AS v FROM schema_migrations;" \
    | jq -r '.[0].results[0].v // 0'
}

apply_up() {
  local db="$1"
  local version="$2"
  local file
  file=$(find_migration_file "$version" "up")
  if [[ -z "$file" ]]; then
    echo "ERROR: no up file for version $version"
    exit 1
  fi
  d1 "$db" --file "$file"
  d1 "$db" --command "INSERT INTO schema_migrations (version) VALUES ($version);"
}

apply_down() {
  local db="$1"
  local version="$2"
  local file
  file=$(find_migration_file "$version" "down")
  if [[ -z "$file" ]]; then
    echo "ERROR: no down file for version $version"
    exit 1
  fi
  d1 "$db" --file "$file"
  d1 "$db" --command "DELETE FROM schema_migrations WHERE version = $version;"
}

# ---- read versions ----------------------------------------------------------

TARGET=$(jq -r '.applied_migration_version' "$CONFIG_FILE")
ensure_migrations_table "$DB_NAME"
ACTUAL=$(get_applied_version "$DB_NAME")

echo "actual=$ACTUAL target=$TARGET"

if [[ "$TARGET" -eq "$ACTUAL" ]]; then
  echo "Already at version $TARGET. Nothing to do."
  exit 0
fi

ensure_migrations_table "$SANDBOX_DB_NAME"

ACTUAL_SNAP=$(snap_file "$ACTUAL")
if [[ ! -f "$ACTUAL_SNAP" ]]; then
  export_snap "$SANDBOX_DB_NAME" "$ACTUAL"
fi

# ---- up ---------------------------------------------------------------------

if [[ "$TARGET" -gt "$ACTUAL" ]]; then
  echo ""
  echo "==> Dry-run: testing migrations $((ACTUAL + 1))..$TARGET on sandbox..."

  FAILED=false
  for ((v = ACTUAL + 1; v <= TARGET; v++)); do
    echo ""
    echo "  [$v] Testing up→down roundtrip..."

    snap_before_file=$(mktemp)
    snap_after_file=$(mktemp)
    npx wrangler d1 export "$SANDBOX_DB_NAME" $REMOTE_FLAG --output="$snap_before_file"

    apply_up "$SANDBOX_DB_NAME" "$v"
    apply_down "$SANDBOX_DB_NAME" "$v"

    npx wrangler d1 export "$SANDBOX_DB_NAME" $REMOTE_FLAG --output="$snap_after_file"

    if ! diff -q "$snap_before_file" "$snap_after_file" > /dev/null 2>&1; then
      rm -f "$snap_before_file" "$snap_after_file"
      echo "  [$v] ROUNDTRIP MISMATCH"
      FAILED=true
      break
    fi

    rm -f "$snap_before_file" "$snap_after_file"
    echo "  [$v] OK"
    apply_up "$SANDBOX_DB_NAME" "$v"
  done

  if [[ "$FAILED" == "true" ]]; then
    echo ""
    echo "Dry-run failed. Restoring sandbox..."
    restore_snap "$SANDBOX_DB_NAME" "$ACTUAL"
    exit 2
  fi

  echo ""
  echo "==> Applying migrations $((ACTUAL + 1))..$TARGET to real DB..."
  for ((v = ACTUAL + 1; v <= TARGET; v++)); do
    echo "  Applying $v..."
    apply_up "$DB_NAME" "$v"
  done

  export_snap "$SANDBOX_DB_NAME" "$TARGET"
  echo ""
  echo "Done. DB is now at version $TARGET."
fi

# ---- down -------------------------------------------------------------------

if [[ "$TARGET" -lt "$ACTUAL" ]]; then
  echo ""
  echo "==> Dry-run: testing rollback $ACTUAL→$TARGET on sandbox..."

  FAILED=false
  for ((v = ACTUAL; v > TARGET; v--)); do
    echo "  [$v] Applying down on sandbox..."
    if ! apply_down "$SANDBOX_DB_NAME" "$v"; then
      FAILED=true
      break
    fi
  done

  if [[ "$FAILED" == "true" ]]; then
    echo ""
    echo "Dry-run failed. Restoring sandbox..."
    restore_snap "$SANDBOX_DB_NAME" "$ACTUAL"
    exit 2
  fi

  export_snap "$SANDBOX_DB_NAME" "$TARGET"

  echo ""
  echo "==> Applying rollback $ACTUAL→$TARGET to real DB..."
  for ((v = ACTUAL; v > TARGET; v--)); do
    echo "  Rolling back $v..."
    apply_down "$DB_NAME" "$v"
  done

  echo ""
  echo "Done. DB is now at version $TARGET."
fi
