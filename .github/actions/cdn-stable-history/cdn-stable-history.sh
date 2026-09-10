#!/usr/bin/env bash
# Maintain a rolling list of the last N stable CDN SHAs in blob storage.
set -euo pipefail

CDN_ACCOUNT_NAME="${CDN_ACCOUNT_NAME:?CDN_ACCOUNT_NAME is required}"
CDN_CONTAINER="${CDN_CONTAINER:?CDN_CONTAINER is required}"
# BLOB_PREFIX is resolved by the cdn-stable-history action via
# cdn-resolve-prefix (<repo>, or <ns>/<repo> when namespaced).
if [ -z "${BLOB_PREFIX+x}" ]; then
  echo "ERROR: BLOB_PREFIX must be set (empty string allowed); run via the cdn-stable-history action" >&2
  exit 1
fi
STABLE_SHA="${STABLE_SHA:?STABLE_SHA is required}"
KEEP_STABLE="${KEEP_STABLE:-5}"

if [ -n "${CDN_SAS_TOKEN:-}" ]; then
  export AZURE_STORAGE_ACCOUNT="$CDN_ACCOUNT_NAME"
  export AZURE_STORAGE_SAS_TOKEN="$CDN_SAS_TOKEN"
fi

HISTORY_BLOB="${BLOB_PREFIX:+$BLOB_PREFIX/}.stable-history"
LOCK_BLOB="${BLOB_PREFIX:+$BLOB_PREFIX/}.stable-history.lock"
TMP=$(mktemp)
EMPTY=$(mktemp)
trap 'rm -f "$TMP" "${TMP}.new" "$EMPTY"' EXIT

# Ensure the lock blob exists. A separate lock blob prevents concurrent
# releases from reading the same history and then overwriting each other.
lock_exists_output=$(az storage blob exists \
  --container-name "$CDN_CONTAINER" \
  --name "$LOCK_BLOB" \
  --query exists -o tsv 2>/dev/null)
lock_exists_exit=$?
if [ "$lock_exists_exit" -ne 0 ]; then
  echo "ERROR: failed to check existence of lock blob ${LOCK_BLOB}" >&2
  exit 1
fi
if [ "$lock_exists_output" != "true" ]; then
  if ! az storage blob upload \
    --container-name "$CDN_CONTAINER" \
    --file "$EMPTY" \
    --name "$LOCK_BLOB" >/dev/null 2>/dev/null; then
    echo "ERROR: failed to create history lock blob ${LOCK_BLOB}" >&2
    exit 1
  fi
fi

lease_id=$(az storage blob lease acquire \
  --container-name "$CDN_CONTAINER" \
  --blob-name "$LOCK_BLOB" \
  --lease-duration 60 \
  --query leaseId -o tsv 2>/dev/null) || {
    echo "ERROR: failed to acquire history update lock on ${LOCK_BLOB}" >&2
    exit 1
  }

release_lock() {
  az storage blob lease release \
    --container-name "$CDN_CONTAINER" \
    --blob-name "$LOCK_BLOB" \
    --lease-id "$lease_id" >/dev/null 2>&1 || true
}
trap 'release_lock; rm -f "$TMP" "${TMP}.new" "$EMPTY"' EXIT

# Download existing history if present; fail on unexpected errors so a transient
# outage does not cause us to drop the history.
history_exists_output=$(az storage blob exists \
  --container-name "$CDN_CONTAINER" \
  --name "$HISTORY_BLOB" \
  --query exists -o tsv 2>/dev/null)
history_exists_exit=$?
if [ "$history_exists_exit" -ne 0 ]; then
  echo "ERROR: failed to check existence of history blob ${HISTORY_BLOB}" >&2
  exit 1
fi
if [ "$history_exists_output" = "true" ]; then
  if ! az storage blob download \
    --container-name "$CDN_CONTAINER" \
    --name "$HISTORY_BLOB" \
    --file "$TMP" 2>/dev/null; then
    echo "ERROR: failed to download existing history blob ${HISTORY_BLOB}" >&2
    exit 1
  fi
fi

# Prepend new SHA, remove duplicates and blanks, keep last KEEP_STABLE.
{
  echo "$STABLE_SHA"
  cat "$TMP"
} | awk 'NF && !seen[$0]++' | head -n "$KEEP_STABLE" > "${TMP}.new"

if ! az storage blob upload \
  --container-name "$CDN_CONTAINER" \
  --file "${TMP}.new" \
  --name "$HISTORY_BLOB" \
  --overwrite; then
  echo "ERROR: failed to upload updated history blob ${HISTORY_BLOB}" >&2
  exit 1
fi
