#!/usr/bin/env bash
# Select and apply the newest seed compatible with a migration version.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../utils/database.sh
. "$SCRIPT_DIR/../utils/database.sh"
# shellcheck source=../utils/seeds.sh
. "$SCRIPT_DIR/../utils/seeds.sh"

TARGET=""
MIGRATION_VERSION=""
SEEDS_DIR="provision/seeds"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --migration-version)
      MIGRATION_VERSION="$2"
      shift 2
      ;;
    --seeds)
      SEEDS_DIR="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

validate_database_authentication
validate_target "$TARGET"

if [[ -z "$MIGRATION_VERSION" ]]; then
  migration_result=$(query_database \
    "$TARGET" \
    "SELECT COALESCE(version, 0) AS version FROM schema_operations WHERE kind = 'migration';")
  MIGRATION_VERSION=$(jq -er '.results[0].version' <<< "$migration_result")
fi

seed_file=$(select_seed_for_migration "$MIGRATION_VERSION" "$SEEDS_DIR")
seed_file_version=$(seed_version "$seed_file")

execute_database_sql "$TARGET" \
  "CREATE TABLE IF NOT EXISTS schema_operations (
     kind TEXT PRIMARY KEY,
     version INTEGER NOT NULL,
     applied_at TEXT NOT NULL DEFAULT (datetime('now'))
   );" > /dev/null

echo "Applying seed $(basename "$seed_file") to $TARGET at migration $MIGRATION_VERSION..."
execute_database_file "$TARGET" "$seed_file" > /dev/null
execute_database_sql "$TARGET" \
  "INSERT INTO schema_operations (kind, version) VALUES ('seed', $seed_file_version)
   ON CONFLICT(kind) DO UPDATE SET version = excluded.version, applied_at = datetime('now');" > /dev/null
echo "Applied seed $(basename "$seed_file")."

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "applied=true" >> "$GITHUB_OUTPUT"
  echo "seed_file=$seed_file" >> "$GITHUB_OUTPUT"
  echo "seed_version=$seed_file_version" >> "$GITHUB_OUTPUT"
fi
