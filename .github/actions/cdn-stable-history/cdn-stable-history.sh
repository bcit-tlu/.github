#!/usr/bin/env bash
# Maintain a rolling list of the last N stable CDN content refs in blob storage.
set -euo pipefail

CDN_ACCOUNT_NAME="${CDN_ACCOUNT_NAME:?CDN_ACCOUNT_NAME is required}"
CDN_CONTAINER="${CDN_CONTAINER:?CDN_CONTAINER is required}"
STABLE_REF="${STABLE_REF:?STABLE_REF is required}"
KEEP_STABLE="${KEEP_STABLE:-5}"

# Enforce a hard minimum of 5 so callers cannot shrink the protection window below a safe floor.
if [ "$KEEP_STABLE" -lt 5 ] 2>/dev/null; then
  echo "::warning::keep_stable=${KEEP_STABLE} is below the minimum of 5; clamping to 5"
  KEEP_STABLE=5
fi

export AZURE_STORAGE_ACCOUNT="$CDN_ACCOUNT_NAME"
AUTH_ARGS=()
if [ -n "${CDN_SAS_TOKEN:-}" ]; then
  export AZURE_STORAGE_SAS_TOKEN="$CDN_SAS_TOKEN"
else
  # No SAS token — assume the job authenticated via azure/login (OIDC UAMI).
  AUTH_ARGS+=(--auth-mode login)
fi

HISTORY_BLOB=".stable-history"
LOCK_BLOB=".stable-history.lock"
TMP=$(mktemp)
EMPTY=$(mktemp)
trap 'rm -f "$TMP" "${TMP}.new" "$EMPTY"' EXIT

# Ensure the lock blob exists. A separate lock blob prevents concurrent releases from reading the same history and then overwriting each other.
lock_exists_output=$(az storage blob exists \
  --container-name "$CDN_CONTAINER" \
  "${AUTH_ARGS[@]}" \
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
  "${AUTH_ARGS[@]}" \
    --file "$EMPTY" \
    --name "$LOCK_BLOB" >/dev/null 2>/dev/null; then
    echo "ERROR: failed to create history lock blob ${LOCK_BLOB}" >&2
    exit 1
  fi
fi

lease_id=$(az storage blob lease acquire \
  --container-name "$CDN_CONTAINER" \
  "${AUTH_ARGS[@]}" \
  --blob-name "$LOCK_BLOB" \
  --lease-duration 60 \
  --query leaseId -o tsv 2>/dev/null) || {
    echo "ERROR: failed to acquire history update lock on ${LOCK_BLOB}" >&2
    exit 1
  }

release_lock() {
  az storage blob lease release \
    --container-name "$CDN_CONTAINER" \
  "${AUTH_ARGS[@]}" \
    --blob-name "$LOCK_BLOB" \
    --lease-id "$lease_id" >/dev/null 2>&1 || true
}
trap 'release_lock; rm -f "$TMP" "${TMP}.new" "$EMPTY"' EXIT

# Download existing history if present; fail on unexpected errors so a transient outage does not cause us to drop the history.
history_exists_output=$(az storage blob exists \
  --container-name "$CDN_CONTAINER" \
  "${AUTH_ARGS[@]}" \
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
  "${AUTH_ARGS[@]}" \
    --name "$HISTORY_BLOB" \
    --file "$TMP" 2>/dev/null; then
    echo "ERROR: failed to download existing history blob ${HISTORY_BLOB}" >&2
    exit 1
  fi
fi

# Prepend new ref, remove duplicates and blanks, keep last KEEP_STABLE.
{
  echo "$STABLE_REF"
  cat "$TMP"
} | awk 'NF && !seen[$0]++' | head -n "$KEEP_STABLE" > "${TMP}.new"

if ! az storage blob upload \
  --container-name "$CDN_CONTAINER" \
  "${AUTH_ARGS[@]}" \
  --file "${TMP}.new" \
  --name "$HISTORY_BLOB" \
  --overwrite; then
  echo "ERROR: failed to upload updated history blob ${HISTORY_BLOB}" >&2
  exit 1
fi

# Write the .stable-current pointer so cleanup deterministically protects the ref the stable environment is currently serving.
echo "$STABLE_REF" > "$TMP"
if ! az storage blob upload \
  --container-name "$CDN_CONTAINER" \
  "${AUTH_ARGS[@]}" \
  --file "$TMP" \
  --name ".stable-current" \
  --overwrite; then
  echo "ERROR: failed to upload .stable-current pointer" >&2
  exit 1
fi
