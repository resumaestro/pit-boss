#!/bin/sh
# Shared helpers for listing migrations and seeds.

# Highest migration version number from a migrations dir.
# Usage: migrations_highest <migrations_dir>
migrations_highest() {
  _mh_dir="${1:-migrations}"
  ls "$_mh_dir"/*.up.sql 2>/dev/null \
    | xargs -I{} basename {} \
    | grep -Eo '^[0-9]+' \
    | sort -n \
    | tail -1
}

# List all migration up files >= a given version, as basenames without extension.
# Usage: migrations_from <version> <migrations_dir>
migrations_from() {
  _mf_min="$1"
  _mf_dir="${2:-migrations}"
  for _mf_file in "$_mf_dir"/*.up.sql; do
    [ -f "$_mf_file" ] || continue
    _mf_ver=$(basename "$_mf_file" | grep -Eo '^[0-9]+')
    [ "$_mf_ver" -ge "$_mf_min" ] && basename "$_mf_file" .up.sql
  done
}

# List all seed up files in order, as full paths.
# Usage: seeds_list <seeds_dir>
seeds_list() {
  _sl_dir="${1:-provision/seeds}"
  for _sl_file in "$_sl_dir"/*.up.sql; do
    [ -f "$_sl_file" ] && printf '%s\n' "$_sl_file"
  done
}

# Extract the 4-digit version number from a seed filename.
seed_version() {
  basename "$1" | grep -Eo '^[0-9]+'
}
