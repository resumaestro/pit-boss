#!/bin/sh
# pit-boss migration
#
# Scaffolds a new migration file pair (up + down) with the next version number.
# Run from the root of the consuming repo.
#
# Usage:
#   pit-boss migration <name>

MIGRATIONS_DIR="${MIGRATIONS_DIR:-provision/migrations}"

NAME="$1"

if [ -z "$NAME" ]; then
  printf 'Usage: pit-boss migration <name>\n' >&2
  exit 1
fi

# Sanitize name: lowercase, spaces to underscores
NAME=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')

mkdir -p "$MIGRATIONS_DIR"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../utils/migrations.sh"

HIGHEST=$(migrations_highest "$MIGRATIONS_DIR")
NEXT=$(printf '%04d' "$(( ${HIGHEST:-0} + 1 ))")

UP_FILE="$MIGRATIONS_DIR/${NEXT}_${NAME}.up.sql"
DOWN_FILE="$MIGRATIONS_DIR/${NEXT}_${NAME}.down.sql"

if [ -f "$UP_FILE" ] || [ -f "$DOWN_FILE" ]; then
  printf 'Error: migration %s already exists\n' "$NEXT" >&2
  exit 1
fi

printf '-- migration %s up: %s\n' "$NEXT" "$NAME" > "$UP_FILE"
printf '-- migration %s down: %s\n' "$NEXT" "$NAME" > "$DOWN_FILE"

printf 'Created:\n  %s\n  %s\n' "$UP_FILE" "$DOWN_FILE"
