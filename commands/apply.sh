#!/bin/sh
# pit-boss apply <name>
#
# Scaffolds a new apply JSON file with the next version number.
# Run from the root of the consuming repo.
#
# Usage:
#   pit-boss apply <name>

APPLIES_DIR="${APPLIES_DIR:-provision/applies}"

NAME="$1"

if [ -z "$NAME" ]; then
  printf 'Usage: pit-boss apply <name>\n' >&2
  exit 1
fi

# Sanitize name: lowercase, spaces to underscores
NAME=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')

mkdir -p "$APPLIES_DIR"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../utils/migrations.sh"

# Find highest existing apply version
HIGHEST=0
for _f in "$APPLIES_DIR"/[0-9]*.json; do
  [ -f "$_f" ] || continue
  _ver=$(basename "$_f" | grep -Eo '^[0-9]+')
  [ "$_ver" -gt "$HIGHEST" ] && HIGHEST="$_ver"
done

NEXT=$(printf '%04d' "$(( HIGHEST + 1 ))")
APPLY_FILE="$APPLIES_DIR/${NEXT}_${NAME}.json"

if [ -f "$APPLY_FILE" ]; then
  printf 'Error: apply %s already exists\n' "$NEXT" >&2
  exit 1
fi

printf '{\n  "payload": {},\n  "target": ""\n}\n' > "$APPLY_FILE"

printf 'Created:\n  %s\n' "$APPLY_FILE"
