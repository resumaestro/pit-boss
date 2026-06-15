#!/usr/bin/env bash
# Shared provision planning logic.
# Sourced by provision.sh and dry-run.sh — not executed directly.
#
# Requires these variables to be set by the caller:
#   MIGRATIONS_DIR, SEEDS_DIR, CURRENT_MIGRATION, CURRENT_SEED, TARGET_MIGRATION
#
# Populates:
#   PENDING_SEED_FILES[]  — seed file paths to apply
#   PENDING_SEED_AT[]     — migration version at which each seed should be applied

# shellcheck source=../../utils/annotations.sh
. "$PLAN_SCRIPT_DIR/../../utils/annotations.sh"
# shellcheck source=../../utils/migrations.sh
. "$PLAN_SCRIPT_DIR/../../utils/migrations.sh"
# shellcheck source=../../utils/seeds.sh
. "$PLAN_SCRIPT_DIR/../../utils/seeds.sh"

declare -a PENDING_SEED_FILES
declare -a PENDING_SEED_AT

mapfile -t ALL_SEED_FILES < <(
  if [[ -d "$SEEDS_DIR" ]]; then
    seeds_list "$SEEDS_DIR" 2>/dev/null || true
  fi
)

for seed_file in "${ALL_SEED_FILES[@]+"${ALL_SEED_FILES[@]}"}"; do
  seed_ver=$(seed_version "$seed_file")
  minimum=$(annotation_get_min "$seed_file" || true)
  maximum=$(annotation_get_max "$seed_file" || true)
  needs_verification=$(annotation_get_needs_verification "$seed_file" || true)

  if ! [[ "$minimum" =~ ^[0-9]+$ ]]; then
    echo "ERROR: seed $(basename "$seed_file") is missing a valid MIGRATION_MIN" >&2
    exit 1
  fi

  if [[ "$seed_ver" -le "$CURRENT_SEED" ]]; then
    continue
  fi

  if [[ "$minimum" -gt "$TARGET_MIGRATION" ]]; then
    continue
  fi

  if [[ "$CURRENT_MIGRATION" -lt "$minimum" ]]; then
    PENDING_SEED_FILES+=("$seed_file")
    PENDING_SEED_AT+=("$minimum")

  elif [[ "$CURRENT_MIGRATION" -eq "$minimum" ]]; then
    PENDING_SEED_FILES+=("$seed_file")
    PENDING_SEED_AT+=("$CURRENT_MIGRATION")

  else
    if [[ -z "$maximum" ]]; then
      echo "ERROR: seed $(basename "$seed_file") has MIGRATION_MIN=$minimum but MAX is unresolved" \
           "(current migration $CURRENT_MIGRATION > MIN). Run pit-boss pre-commit to resolve." >&2
      exit 1
    fi
    if [[ "$needs_verification" == "true" ]]; then
      echo "ERROR: seed $(basename "$seed_file") still has NEEDS_VERIFICATION=true" >&2
      exit 1
    fi
    if [[ "$CURRENT_MIGRATION" -gt "$maximum" ]]; then
      echo "WARNING: seed $(basename "$seed_file") window [$minimum,$maximum] already passed" \
           "(current migration $CURRENT_MIGRATION). Skipping."
      continue
    fi
    PENDING_SEED_FILES+=("$seed_file")
    PENDING_SEED_AT+=("$CURRENT_MIGRATION")
  fi
done

if [[ ! -d "$MIGRATIONS_DIR" ]]; then
  echo "WARNING: migrations dir '$MIGRATIONS_DIR' not found; no migrations will be applied."
fi

echo ""
echo "Plan:"
echo "  Migration: $CURRENT_MIGRATION → $TARGET_MIGRATION"
for i in "${!PENDING_SEED_FILES[@]}"; do
  echo "  Seed $(basename "${PENDING_SEED_FILES[$i]}") → at migration ${PENDING_SEED_AT[$i]}"
done

# ---- shared helpers ---------------------------------------------------------

find_migration_file() {
  local version="$1" direction="$2" padded
  [[ ! -d "$MIGRATIONS_DIR" ]] && return
  padded=$(printf "%04d" "$version")
  ls "$MIGRATIONS_DIR"/${padded}_*.${direction}.sql 2>/dev/null | head -1 || true
}

apply_migration_up() {
  local target="$1" version="$2" file
  file=$(find_migration_file "$version" "up")
  [[ -z "$file" ]] && { echo "ERROR: no up file for migration $version" >&2; exit 1; }
  execute_database_file "$target" "$file" > /dev/null
  execute_database_sql "$target" \
    "INSERT INTO schema_operations (kind, version) VALUES ('migration', $version)
     ON CONFLICT(kind) DO UPDATE SET version = excluded.version, applied_at = datetime('now');" > /dev/null
  echo "  [migration $version] ↑ $target"
}

apply_migration_down() {
  local target="$1" version="$2" file
  file=$(find_migration_file "$version" "down")
  [[ -z "$file" ]] && { echo "ERROR: no down file for migration $version" >&2; exit 1; }
  execute_database_file "$target" "$file" > /dev/null
  execute_database_sql "$target" \
    "INSERT INTO schema_operations (kind, version) VALUES ('migration', $((version - 1)))
     ON CONFLICT(kind) DO UPDATE SET version = excluded.version, applied_at = datetime('now');" > /dev/null
  echo "  [migration $version] ↓ $target"
}

apply_seed() {
  local target="$1" seed_file="$2" seed_ver
  seed_ver=$(seed_version "$seed_file")
  execute_database_file "$target" "$seed_file" > /dev/null
  execute_database_sql "$target" \
    "INSERT INTO schema_operations (kind, version) VALUES ('seed', $seed_ver)
     ON CONFLICT(kind) DO UPDATE SET version = excluded.version, applied_at = datetime('now');" > /dev/null
  echo "  [seed $seed_ver] applied to $target"
}

seeds_pending_at() {
  local at_version="$1"
  for i in "${!PENDING_SEED_FILES[@]}"; do
    [[ "${PENDING_SEED_AT[$i]}" -eq "$at_version" ]] && printf '%s\n' "${PENDING_SEED_FILES[$i]}"
  done
}

ensure_schema_operations() {
  local target="$1"
  execute_database_sql "$target" "
    CREATE TABLE IF NOT EXISTS schema_operations (
      kind       TEXT PRIMARY KEY,
      version    INTEGER NOT NULL,
      applied_at TEXT NOT NULL DEFAULT (datetime('now'))
    );" > /dev/null
}
