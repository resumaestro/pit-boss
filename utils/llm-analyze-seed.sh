#!/bin/sh
# LLM-based seed MAX analysis (rule 5).
# Prints a single integer (the resolved MAX) to stdout, or nothing on failure.
#
# Usage: llm-analyze-seed.sh <seed_file> <min> <highest> <migrations_dir>

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/../config/models.sh"

SEED_FILE="$1"
MIN="$2"
HIGHEST="$3"
MIGRATIONS_DIR="${4:-migrations}"

if [ -z "$ANTHROPIC_API_KEY" ]; then
  printf 'llm-analyze-seed: ANTHROPIC_API_KEY not set\n' >&2
  exit 1
fi

# Build context: seed SQL + all migration up files from MIN+1 to HIGHEST
_seed_sql=$(cat "$SEED_FILE")
_migrations_context=""
_v=$((MIN + 1))
while [ "$_v" -le "$HIGHEST" ]; do
  _mf=$(ls "$MIGRATIONS_DIR"/$(printf '%04d' "$_v")_*.up.sql 2>/dev/null | head -1)
  if [ -n "$_mf" ]; then
    _migrations_context=$(printf '%s\n\n-- migration %s --\n%s' \
      "$_migrations_context" "$_v" "$(cat "$_mf")")
  fi
  _v=$((_v + 1))
done

_prompt=$(printf \
'You are analyzing SQL migration compatibility. A seed file was written against migration %s.
Given the following migrations (from %s to %s), determine the highest migration version
the seed is still compatible with. Consider ALTER TABLE, DROP TABLE, RENAME, column changes, etc.

Respond with ONLY a single integer — the highest compatible migration version. No explanation.

SEED FILE:
%s

MIGRATIONS:
%s' \
  "$MIN" "$((MIN + 1))" "$HIGHEST" "$_seed_sql" "$_migrations_context")

_payload=$(printf '{"model":"%s","max_tokens":16,"messages":[{"role":"user","content":%s}]}' \
  "$HAIKU_MODEL" \
  "$(printf '%s' "$_prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")

_response=$(curl -sf https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$_payload")

printf '%s' "$_response" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["content"][0]["text"].strip())' \
  | grep -Eo '^[0-9]+$'
