#!/usr/bin/env bash
# Helpers for selecting migration-compatible seed files.

set -euo pipefail

SEEDS_UTILS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=annotations.sh
. "$SEEDS_UTILS_DIR/annotations.sh"
# shellcheck source=migrations.sh
. "$SEEDS_UTILS_DIR/migrations.sh"

select_seed_for_migration() {
  local migration_version="$1"
  local seeds_dir="${2:-provision/seeds}"
  local selected_file=""
  local selected_version=-1
  local seed_file

  if ! [[ "$migration_version" =~ ^[0-9]+$ ]]; then
    echo "ERROR: migration version must be a non-negative integer." >&2
    return 1
  fi

  while IFS= read -r seed_file; do
    local minimum
    local maximum
    local needs_verification
    local seed_file_version

    minimum=$(annotation_get_min "$seed_file" || true)
    maximum=$(annotation_get_max "$seed_file" || true)
    needs_verification=$(annotation_get_needs_verification "$seed_file" || true)
    seed_file_version=$(seed_version "$seed_file" || true)

    if ! [[ "$seed_file_version" =~ ^[0-9]+$ ]]; then
      echo "ERROR: seed filename must start with a numeric version: $seed_file" >&2
      return 1
    fi

    if ! [[ "$minimum" =~ ^[0-9]+$ ]]; then
      echo "ERROR: seed is missing a valid MIGRATION_MIN: $seed_file" >&2
      return 1
    fi

    if (( migration_version < minimum )); then
      continue
    fi

    if [[ -z "$maximum" ]]; then
      echo "ERROR: seed has an unresolved MIGRATION_MAX: $seed_file" >&2
      return 1
    fi

    if ! [[ "$maximum" =~ ^[0-9]+$ ]]; then
      echo "ERROR: seed has an invalid MIGRATION_MAX: $seed_file" >&2
      return 1
    fi

    if (( migration_version > maximum )); then
      continue
    fi

    if [[ "$needs_verification" == "true" ]]; then
      echo "ERROR: compatible seed still needs verification: $seed_file" >&2
      return 1
    fi

    if (( seed_file_version == selected_version )); then
      echo "ERROR: multiple compatible seeds use version $seed_file_version." >&2
      return 1
    fi

    if (( seed_file_version > selected_version )); then
      selected_file="$seed_file"
      selected_version=$seed_file_version
    fi
  done < <(seeds_list "$seeds_dir")

  if [[ -z "$selected_file" ]]; then
    echo "ERROR: no seed is compatible with migration $migration_version." >&2
    return 1
  fi

  printf '%s\n' "$selected_file"
}
