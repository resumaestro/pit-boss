#!/bin/sh
# Pre-commit hook: resolve MIGRATION_MAX for seeds that don't have one.
#
# Resolution chain:
#   1. If MIN == highest migration  → MAX = MIN
#   2. If a higher seed's MAX == this seed's MIN  → MAX = MIN
#   3. Heuristic: test if MIN+1 breaks this seed  → MAX = MIN
#   4. Ask the user interactively
#   5. LLM analysis (non-interactive fallback)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../utils/annotations.sh"
. "$SCRIPT_DIR/../utils/migrations.sh"
. "$SCRIPT_DIR/../utils/select.sh"

MIGRATIONS_DIR="${MIGRATIONS_DIR:-provision/migrations}"
SEEDS_DIR="${SEEDS_DIR:-provision/seeds}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

HIGHEST=$(migrations_highest "$MIGRATIONS_DIR")
if [ -z "$HIGHEST" ]; then
  printf 'pit-boss: no migrations found in %s, skipping seed MAX resolution\n' "$MIGRATIONS_DIR"
  exit 0
fi

# Collect all seed up files in order
_seed_files=""
for _f in "$SEEDS_DIR"/*.up.sql; do
  [ -f "$_f" ] && _seed_files="$_seed_files $_f"
done

if [ -z "$_seed_files" ]; then
  exit 0
fi

# ---- pass 1: resolve rules 1 and 2 -----------------------------------------

# Build an array of (file, min, max) by iterating seeds in reverse for rule 2.
# We store resolved MAXes so lower seeds can reference them.

# First pass forward: collect mins and existing maxes
_i=0
for _f in $_seed_files; do
  eval "_sf_$_i=\"$_f\""
  eval "_min_$_i=\"$(annotation_get_min "$_f")\""
  eval "_max_$_i=\"$(annotation_get_max "$_f")\""
  _i=$((_i + 1))
done
_total=$_i

# Rule 1: MIN == highest → MAX = MIN
_i=0
while [ "$_i" -lt "$_total" ]; do
  eval "_min=\"\$_min_$_i\""
  eval "_max=\"\$_max_$_i\""
  if [ -z "$_max" ] && [ "$_min" = "$HIGHEST" ]; then
    eval "_max_$_i=\"$_min\""
    printf 'Rule 1: seed %s MIN=%s == highest migration, setting MAX=%s\n' \
      "$(eval echo \$_sf_$_i | xargs basename)" "$_min" "$_min"
  fi
  _i=$((_i + 1))
done

# Rule 2: higher seed's MAX == lower seed's MIN → lower MAX = MIN
# Iterate pairs: for each seed without MAX, check all higher seeds
_i=0
while [ "$_i" -lt "$_total" ]; do
  eval "_max=\"\$_max_$_i\""
  if [ -z "$_max" ]; then
    eval "_min=\"\$_min_$_i\""
    _j=$((_i + 1))
    while [ "$_j" -lt "$_total" ]; do
      eval "_higher_max=\"\$_max_$_j\""
      if [ -n "$_higher_max" ] && [ "$_higher_max" = "$_min" ]; then
        eval "_max_$_i=\"$_min\""
        printf 'Rule 2: seed %s MAX=%s matches seed %s MIN=%s, setting MAX=%s\n' \
          "$(eval echo \$_sf_$_j | xargs basename)" "$_higher_max" \
          "$(eval echo \$_sf_$_i | xargs basename)" "$_min" "$_min"
        break
      fi
      _j=$((_j + 1))
    done
  fi
  _i=$((_i + 1))
done

# ---- pass 2: rule 3 heuristic -----------------------------------------------
# For each seed still without MAX, test if MIN+1 migration breaks it.
# "Breaks" here means the seed's SQL references objects altered by that migration.
# We do a lightweight static check: extract table names touched by migration MIN+1
# and see if the seed file references any of them via ALTER/DROP/RENAME keywords.

_tables_from_migration() {
  _tfm_ver="$1"
  _tfm_file=$(ls "$MIGRATIONS_DIR"/$(printf '%04d' "$_tfm_ver")_*.up.sql 2>/dev/null | head -1)
  [ -z "$_tfm_file" ] && return
  # Extract table names after ALTER TABLE, DROP TABLE, RENAME TABLE
  grep -iEo '(ALTER|DROP|RENAME)\s+TABLE\s+[`"]?[a-zA-Z_][a-zA-Z0-9_]*[`"]?' "$_tfm_file" \
    | grep -iEo '[a-zA-Z_][a-zA-Z0-9_]*$'
}

_seed_references_tables() {
  _srt_seed="$1"
  _srt_tables="$2"
  for _tbl in $_srt_tables; do
    grep -qi "$_tbl" "$_srt_seed" && return 0
  done
  return 1
}

_i=0
while [ "$_i" -lt "$_total" ]; do
  eval "_max=\"\$_max_$_i\""
  if [ -z "$_max" ]; then
    eval "_min=\"\$_min_$_i\""
    eval "_sf=\"\$_sf_$_i\""
    _next_ver=$((_min + 1))
    _touched=$(_tables_from_migration "$_next_ver")
    if [ -n "$_touched" ] && _seed_references_tables "$_sf" "$_touched"; then
      eval "_max_$_i=\"$_min\""
      printf 'Rule 3: migration %s alters tables referenced by seed %s, setting MAX=%s\n' \
        "$_next_ver" "$(basename "$_sf")" "$_min"
    fi
  fi
  _i=$((_i + 1))
done

# ---- pass 3: rule 4 ask user / rule 5 LLM -----------------------------------

_i=0
while [ "$_i" -lt "$_total" ]; do
  eval "_max=\"\$_max_$_i\""
  if [ -z "$_max" ]; then
    eval "_min=\"\$_min_$_i\""
    eval "_sf=\"\$_sf_$_i\""
    _seed_name=$(basename "$_sf" .up.sql)

    if [ "$NON_INTERACTIVE" = "true" ]; then
      # Rule 5: LLM analysis
      printf 'Rule 5: LLM analysis for %s (MIN=%s)...\n' "$_seed_name" "$_min"
      _llm_max=$("$SCRIPT_DIR/../utils/llm-analyze-seed.sh" "$_sf" "$_min" "$HIGHEST" "$MIGRATIONS_DIR" 2>/dev/null)
      if printf '%s' "$_llm_max" | grep -qE '^[0-9]+$'; then
        eval "_max_$_i=\"$_llm_max\""
        printf 'Rule 5: LLM determined MAX=%s for %s\n' "$_llm_max" "$_seed_name"
      else
        printf 'WARNING: could not determine MAX for %s — NEEDS_VERIFICATION left set\n' "$_seed_name"
        annotation_set_needs_verification "$_sf" "true"
      fi
    else
      # Rule 4: ask the user
      printf '\n'
      printf 'pit-boss: could not auto-determine MAX for seed %s (MIN=%s)\n' "$_seed_name" "$_min"

      # Build options: migration names from MIN onward + "Decide later"
      _opts=""
      for _name in $(migrations_from "$_min" "$MIGRATIONS_DIR"); do
        _opts="$_opts $_name"
      done
      _opts="$_opts Decide later"

      interactive_select \
        "Which migration is the highest that seed $_seed_name works against?" \
        "true" "false" "false" \
        $_opts

      if [ "$PICKER_LABEL" = "Decide later" ] || [ -z "$PICKER_LABEL" ]; then
        printf 'Skipping MAX for %s — NEEDS_VERIFICATION set\n' "$_seed_name"
        annotation_set_needs_verification "$_sf" "true"
      else
        _chosen_ver=$(printf '%s' "$PICKER_LABEL" | grep -Eo '^[0-9]+')
        eval "_max_$_i=\"$_chosen_ver\""
        printf 'Set MAX=%s for %s\n' "$_chosen_ver" "$_seed_name"
      fi
    fi
  fi
  _i=$((_i + 1))
done

# ---- write resolved MAXes back to files -------------------------------------

_i=0
while [ "$_i" -lt "$_total" ]; do
  eval "_sf=\"\$_sf_$_i\""
  eval "_min=\"\$_min_$_i\""
  eval "_max=\"\$_max_$_i\""
  _existing_max=$(annotation_get_max "$_sf")
  if [ -n "$_max" ] && [ "$_max" != "$_existing_max" ]; then
    annotation_set_max "$_sf" "$_max"
    annotation_remove_needs_verification "$_sf"
    printf 'Wrote MIGRATION_MAX=%s to %s\n' "$_max" "$(basename "$_sf")"
    # Stage the updated file
    git add "$_sf"
  fi
  _i=$((_i + 1))
done
