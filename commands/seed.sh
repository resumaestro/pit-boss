#!/bin/sh
# pit-boss seed [--min=N] [locked]
#
# Annotates a new seed file with MIGRATION_MIN/MAX headers.
# Run from the root of the consuming repo.
#
# Usage:
#   pit-boss seed <file>            MIN=highest, MAX=null
#   pit-boss seed <file> locked     MIN=MAX=highest
#   pit-boss seed <file> --min=N    MIN=N, MAX=null, NEEDS_VERIFICATION=true

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../utils/annotations.sh"
. "$SCRIPT_DIR/../utils/migrations.sh"

MIGRATIONS_DIR="${MIGRATIONS_DIR:-migrations}"
MODE="open"
CUSTOM_MIN=""
SEED_FILE=""

for _arg in "$@"; do
  case "$_arg" in
    locked)     MODE="locked" ;;
    --min=*)    MODE="custom"; CUSTOM_MIN="${_arg#--min=}" ;;
    -*)         printf 'Unknown flag: %s\n' "$_arg" >&2; exit 1 ;;
    *)          SEED_FILE="$_arg" ;;
  esac
done

if [ -z "$SEED_FILE" ]; then
  printf 'Usage: pit-boss seed <file> [locked|--min=N]\n' >&2
  exit 1
fi

if [ ! -f "$SEED_FILE" ]; then
  printf 'Error: file not found: %s\n' "$SEED_FILE" >&2
  exit 1
fi

HIGHEST=$(migrations_highest "$MIGRATIONS_DIR")

if [ -z "$HIGHEST" ]; then
  printf 'Error: no migrations found in %s\n' "$MIGRATIONS_DIR" >&2
  exit 1
fi

case "$MODE" in
  open)
    annotation_write "$SEED_FILE" "$HIGHEST" "" ""
    printf 'Annotated %s with MIGRATION_MIN=%s (MAX open)\n' "$SEED_FILE" "$HIGHEST"
    ;;
  locked)
    annotation_write "$SEED_FILE" "$HIGHEST" "$HIGHEST" ""
    printf 'Annotated %s with MIGRATION_MIN=%s MIGRATION_MAX=%s\n' "$SEED_FILE" "$HIGHEST" "$HIGHEST"
    ;;
  custom)
    if ! printf '%s' "$CUSTOM_MIN" | grep -qE '^[0-9]+$'; then
      printf 'Error: --min must be an integer, got: %s\n' "$CUSTOM_MIN" >&2
      exit 1
    fi
    if [ "$CUSTOM_MIN" -gt "$HIGHEST" ]; then
      printf 'Error: --min=%s exceeds highest migration %s\n' "$CUSTOM_MIN" "$HIGHEST" >&2
      exit 1
    fi
    annotation_write "$SEED_FILE" "$CUSTOM_MIN" "" "true"
    printf 'Annotated %s with MIGRATION_MIN=%s (MAX open, NEEDS_VERIFICATION=true)\n' "$SEED_FILE" "$CUSTOM_MIN"
    ;;
esac
