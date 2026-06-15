#!/bin/sh
# Helpers for reading and writing pit-boss seed header annotations.
#
# Header format (first lines of a seed file):
#   -- pit-boss: MIGRATION_MIN=N
#   -- pit-boss: MIGRATION_MAX=N
#   -- pit-boss: NEEDS_VERIFICATION=true

_annotation_get() {
  _ag_file="$1"
  _ag_key="$2"
  grep "^-- pit-boss: ${_ag_key}=" "$_ag_file" 2>/dev/null \
    | head -1 \
    | sed "s/^-- pit-boss: ${_ag_key}=//"
}

_annotation_set() {
  _as_file="$1"
  _as_key="$2"
  _as_val="$3"
  _as_line="-- pit-boss: ${_as_key}=${_as_val}"

  if grep -q "^-- pit-boss: ${_as_key}=" "$_as_file" 2>/dev/null; then
    # Replace existing line
    _as_tmp=$(mktemp)
    sed "s|^-- pit-boss: ${_as_key}=.*|${_as_line}|" "$_as_file" > "$_as_tmp"
    mv "$_as_tmp" "$_as_file"
  else
    # Prepend to file
    _as_tmp=$(mktemp)
    printf '%s\n' "$_as_line" | cat - "$_as_file" > "$_as_tmp"
    mv "$_as_tmp" "$_as_file"
  fi
}

_annotation_remove() {
  _ar_file="$1"
  _ar_key="$2"
  _ar_tmp=$(mktemp)
  grep -v "^-- pit-boss: ${_ar_key}=" "$_ar_file" > "$_ar_tmp"
  mv "$_ar_tmp" "$_ar_file"
}

annotation_get_min() { _annotation_get "$1" "MIGRATION_MIN"; }
annotation_get_max() { _annotation_get "$1" "MIGRATION_MAX"; }
annotation_get_needs_verification() { _annotation_get "$1" "NEEDS_VERIFICATION"; }

annotation_set_min() { _annotation_set "$1" "MIGRATION_MIN" "$2"; }
annotation_set_max() { _annotation_set "$1" "MIGRATION_MAX" "$2"; }
annotation_set_needs_verification() { _annotation_set "$1" "NEEDS_VERIFICATION" "$2"; }
annotation_remove_needs_verification() { _annotation_remove "$1" "NEEDS_VERIFICATION"; }

annotation_write() {
  _aw_file="$1"
  _aw_min="$2"
  _aw_max="$3"       # pass empty string for null
  _aw_verify="$4"    # pass empty string to omit

  # Remove all existing pit-boss headers first
  _aw_tmp=$(mktemp)
  grep -v "^-- pit-boss:" "$_aw_file" > "$_aw_tmp" || true

  # Build header block
  _aw_header=""
  [ -n "$_aw_verify" ] && _aw_header="-- pit-boss: NEEDS_VERIFICATION=${_aw_verify}
${_aw_header}"
  [ -n "$_aw_max" ] && _aw_header="-- pit-boss: MIGRATION_MAX=${_aw_max}
${_aw_header}"
  _aw_header="-- pit-boss: MIGRATION_MIN=${_aw_min}
${_aw_header}"

  printf '%s\n' "$_aw_header" | cat - "$_aw_tmp" > "$_aw_file"
  rm -f "$_aw_tmp"
}
