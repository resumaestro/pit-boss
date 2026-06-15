#!/usr/bin/env bash
# Apply all versioned config files up to the target version through Oboist's /apply endpoint.

set -euo pipefail

APPLIES_DIR="provision/applies"
TARGET=""
TARGET_VERSION=""
SHA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --applies)
      APPLIES_DIR="$2"
      shift 2
      ;;
    --target)
      TARGET="$2"
      shift 2
      ;;
    --version)
      TARGET_VERSION="$2"
      shift 2
      ;;
    --sha)
      SHA="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${PROXY_URL:-}" || -z "${PROXY_TOKEN:-}" ]]; then
  echo "ERROR: PROXY_URL and PROXY_TOKEN are required." >&2
  exit 1
fi

if [[ -z "$TARGET" ]]; then
  echo "ERROR: --target is required." >&2
  exit 1
fi

if [[ -z "$TARGET_VERSION" ]]; then
  echo "ERROR: --version is required." >&2
  exit 1
fi

if ! [[ "$TARGET_VERSION" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --version must be a non-negative integer." >&2
  exit 1
fi

# Fetch current applied version from Oboist
current_response=$(curl \
  --silent \
  --show-error \
  --fail-with-body \
  --request GET \
  "${PROXY_URL%/}/status/${TARGET}?kind=apply" \
  --header "Authorization: Bearer ${PROXY_TOKEN}")

CURRENT_VERSION=$(printf '%s' "$current_response" | jq -r '.version // 0')

if [[ "$TARGET_VERSION" -le "$CURRENT_VERSION" ]]; then
  echo "Config already at version $CURRENT_VERSION; nothing to apply."
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "applied=false" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

# Apply all files from current+1 to target in order
last_applied_file=""
last_applied_version=""

for apply_file in $(ls "$APPLIES_DIR"/[0-9]*.json 2>/dev/null | sort); do
  file_version=$(basename "$apply_file" | grep -Eo '^[0-9]+' | sed 's/^0*//')
  file_version=${file_version:-0}

  [[ "$file_version" -le "$CURRENT_VERSION" ]] && continue
  [[ "$file_version" -gt "$TARGET_VERSION" ]] && break

  apply_key=$(basename "$apply_file")

  payload=$(jq -n \
    --argjson version "$file_version" \
    --arg sha "${SHA:-}" \
    --arg target "$TARGET" \
    --slurpfile file "$apply_file" \
    '{version: $version, sha: $sha, target: $target, payload: $file[0]}')

  response_file=$(mktemp)

  echo "Applying config $apply_key..."

  if ! printf '%s' "$payload" \
    | curl \
      --silent \
      --show-error \
      --fail-with-body \
      --request POST \
      "${PROXY_URL%/}/apply?key=${apply_key}" \
      --header "Authorization: Bearer ${PROXY_TOKEN}" \
      --header "Content-Type: application/json" \
      --data-binary @- \
      > "$response_file"; then
    cat "$response_file" >&2
    rm -f "$response_file"
    exit 1
  fi

  echo "Applied $apply_key."
  rm -f "$response_file"

  last_applied_file="$apply_file"
  last_applied_version="$file_version"
done

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  if [[ -n "$last_applied_version" ]]; then
    echo "applied=true" >> "$GITHUB_OUTPUT"
    echo "apply_file=$last_applied_file" >> "$GITHUB_OUTPUT"
    echo "apply_version=$last_applied_version" >> "$GITHUB_OUTPUT"
  else
    echo "applied=false" >> "$GITHUB_OUTPUT"
  fi
fi
