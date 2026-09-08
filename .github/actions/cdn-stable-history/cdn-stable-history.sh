#!/usr/bin/env bash
# Maintain a rolling list of the last N stable CDN SHAs in blob storage.
set -euo pipefail

CDN_ACCOUNT_NAME="${CDN_ACCOUNT_NAME:?CDN_ACCOUNT_NAME is required}"
CDN_CONTAINER="${CDN_CONTAINER:?CDN_CONTAINER is required}"
CDN_NAMESPACE="${CDN_NAMESPACE:-}"
[ "$CDN_NAMESPACE" = "none" ] && CDN_NAMESPACE=""
REPO_NAME="${REPO_NAME:?REPO_NAME is required}"
STABLE_SHA="${STABLE_SHA:?STABLE_SHA is required}"
KEEP_STABLE="${KEEP_STABLE:-5}"

if [ -n "${CDN_SAS_TOKEN:-}" ]; then
  export AZURE_STORAGE_ACCOUNT="$CDN_ACCOUNT_NAME"
  export AZURE_STORAGE_SAS_TOKEN="$CDN_SAS_TOKEN"
fi

if [ -n "$CDN_NAMESPACE" ]; then
  BLOB_PREFIX="${CDN_NAMESPACE}/${REPO_NAME}"
elif [ "$CDN_CONTAINER" = "$REPO_NAME" ]; then
  BLOB_PREFIX=""
else
  BLOB_PREFIX="${REPO_NAME}"
fi

HISTORY_BLOB="${BLOB_PREFIX:+$BLOB_PREFIX/}.stable-history"
TMP=$(mktemp)
trap 'rm -f "$TMP" "${TMP}.new"' EXIT

# Download existing history if present; ignore 404 on first run.
az storage blob download \
  --container-name "$CDN_CONTAINER" \
  --name "$HISTORY_BLOB" \
  --file "$TMP" 2>/dev/null || true

# Prepend new SHA, remove duplicates and blanks, keep last KEEP_STABLE.
{
  echo "$STABLE_SHA"
  cat "$TMP"
} | awk 'NF && !seen[$0]++' | head -n "$KEEP_STABLE" > "${TMP}.new"

az storage blob upload \
  --container-name "$CDN_CONTAINER" \
  --file "${TMP}.new" \
  --name "$HISTORY_BLOB" \
  --overwrite
