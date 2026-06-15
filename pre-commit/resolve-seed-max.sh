#!/usr/bin/env bash
# Pre-commit hook: resolve MIGRATION_MAX for seeds that don't have one.
#
# Resolution chain (repeated until stable):
#   1. MIN == highest migration  → MAX = MIN
#   2. Higher seed MAX == this seed MIN  → MAX = MIN
#   3. Heuristic: migration MIN+1 alters tables this seed touches  → MAX = MIN
#   4. Ask the user interactively
#   5. LLM analysis (non-interactive fallback)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=../utils/annotations.sh
. "$SCRIPT_DIR/../utils/annotations.sh"
# shellcheck source=../utils/migrations.sh
. "$SCRIPT_DIR/../utils/migrations.sh"
# shellcheck source=../utils/select.sh
. "$SCRIPT_DIR/../utils/select.sh"

MIGRATIONS_DIR="${MIGRATIONS_DIR:-provision/migrations}"
SEEDS_DIR="${SEEDS_DIR:-provision/seeds}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

HIGHEST=$(migrations_highest "$MIGRATIONS_DIR")
if [[ -z "$HIGHEST" ]]; then
  echo "pit-boss: no migrations found in $MIGRATIONS_DIR, skipping seed MAX resolution"
  exit 0
fi

# Collect all seed up files in order
mapfile -t SEED_FILES < <(seeds_list "$SEEDS_DIR")

if [[ ${#SEED_FILES[@]} -eq 0 ]]; then
  exit 0
fi

# Load current annotations into parallel arrays
declare -a SEED_MIN SEED_MAX
for i in "${!SEED_FILES[@]}"; do
  SEED_MIN[$i]=$(annotation_get_min "${SEED_FILES[$i]}" || true)
  SEED_MAX[$i]=$(annotation_get_max "${SEED_FILES[$i]}" || true)
done

# ---- helpers ----------------------------------------------------------------

tables_from_migration() {
  local version="$1"
  local file
  file=$(ls "$MIGRATIONS_DIR"/$(printf '%04d' "$version")_*.up.sql 2>/dev/null | head -1 || true)
  [[ -z "$file" ]] && return
  grep -iEo '(ALTER|DROP|RENAME)[[:space:]]+TABLE[[:space:]]+[`"]?[a-zA-Z_][a-zA-Z0-9_]*[`"]?' "$file" \
    | grep -iEo '[a-zA-Z_][a-zA-Z0-9_]*$' || true
}

seed_references_tables() {
  local seed="$1"
  local tables="$2"
  local tbl
  for tbl in $tables; do
    grep -qi "$tbl" "$seed" && return 0
  done
  return 1
}

# ---- multi-pass fixed-point iteration: rules 1 and 2 -----------------------

changed=true
while [[ "$changed" == "true" ]]; do
  changed=false

  for i in "${!SEED_FILES[@]}"; do
    [[ -n "${SEED_MAX[$i]}" ]] && continue
    min="${SEED_MIN[$i]}"

    # Rule 1
    if [[ "$min" == "$HIGHEST" ]]; then
      SEED_MAX[$i]="$min"
      echo "Rule 1: $(basename "${SEED_FILES[$i]}") MIN=$min == highest migration, setting MAX=$min"
      changed=true
      continue
    fi

    # Rule 2: any higher seed whose MAX == this seed's MIN
    for j in "${!SEED_FILES[@]}"; do
      [[ "$j" -le "$i" ]] && continue
      [[ -z "${SEED_MAX[$j]}" ]] && continue
      if [[ "${SEED_MAX[$j]}" == "$min" ]]; then
        SEED_MAX[$i]="$min"
        echo "Rule 2: $(basename "${SEED_FILES[$j]}") MAX=${SEED_MAX[$j]} == $(basename "${SEED_FILES[$i]}") MIN=$min, setting MAX=$min"
        changed=true
        break
      fi
    done
  done
done

# ---- rule 3: heuristic ------------------------------------------------------

for i in "${!SEED_FILES[@]}"; do
  [[ -n "${SEED_MAX[$i]}" ]] && continue
  min="${SEED_MIN[$i]}"
  next_ver=$(( min + 1 ))
  touched=$(tables_from_migration "$next_ver")
  if [[ -n "$touched" ]] && seed_references_tables "${SEED_FILES[$i]}" "$touched"; then
    SEED_MAX[$i]="$min"
    echo "Rule 3: migration $next_ver alters tables referenced by $(basename "${SEED_FILES[$i]}"), setting MAX=$min"
  fi
done

# ---- rules 4 and 5: user / LLM ----------------------------------------------

for i in "${!SEED_FILES[@]}"; do
  [[ -n "${SEED_MAX[$i]}" ]] && continue
  seed_name=$(basename "${SEED_FILES[$i]}" .up.sql)
  min="${SEED_MIN[$i]}"

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    # Rule 5: LLM
    echo "Rule 5: LLM analysis for $seed_name (MIN=$min)..."
    llm_max=$("$SCRIPT_DIR/../utils/llm-analyze-seed.sh" "${SEED_FILES[$i]}" "$min" "$HIGHEST" "$MIGRATIONS_DIR" 2>/dev/null || true)
    if [[ "$llm_max" =~ ^[0-9]+$ ]]; then
      SEED_MAX[$i]="$llm_max"
      echo "Rule 5: LLM determined MAX=$llm_max for $seed_name"
    else
      echo "WARNING: could not determine MAX for $seed_name — NEEDS_VERIFICATION left set"
      annotation_set_needs_verification "${SEED_FILES[$i]}" "true"
    fi
  else
    # Rule 4: ask the user
    echo ""
    echo "pit-boss: could not auto-determine MAX for seed $seed_name (MIN=$min)"

    mapfile -t migration_options < <(migrations_from "$min" "$MIGRATIONS_DIR")
    migration_options+=("Decide later")

    interactive_select \
      "Which migration is the highest that seed $seed_name works against?" \
      "true" "false" "false" \
      "${migration_options[@]}"

    if [[ "$PICKER_LABEL" == "Decide later" ]] || [[ -z "$PICKER_LABEL" ]]; then
      echo "Skipping MAX for $seed_name — NEEDS_VERIFICATION set"
      annotation_set_needs_verification "${SEED_FILES[$i]}" "true"
    else
      chosen_ver=$(printf '%s' "$PICKER_LABEL" | grep -Eo '^[0-9]+')
      SEED_MAX[$i]="$chosen_ver"
      echo "Set MAX=$chosen_ver for $seed_name"
    fi
  fi
done

# ---- write resolved MAXes back to files -------------------------------------

for i in "${!SEED_FILES[@]}"; do
  [[ -z "${SEED_MAX[$i]}" ]] && continue
  existing_max=$(annotation_get_max "${SEED_FILES[$i]}" || true)
  if [[ "${SEED_MAX[$i]}" != "$existing_max" ]]; then
    annotation_set_max "${SEED_FILES[$i]}" "${SEED_MAX[$i]}"
    annotation_remove_needs_verification "${SEED_FILES[$i]}"
    echo "Wrote MIGRATION_MAX=${SEED_MAX[$i]} to $(basename "${SEED_FILES[$i]}")"
    git add "${SEED_FILES[$i]}"
  fi
done
