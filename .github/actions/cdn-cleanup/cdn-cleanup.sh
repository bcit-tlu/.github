#!/usr/bin/env bash
# Delete unreferenced CDN SHA prefixes. Protection is deterministic:
#   .latest-current  — the SHA the latest environment is transitioning to
#   .latest-history  — last N latest SHAs (rollout-lag + rollback window)
#   .stable-current  — the SHA the stable environment is currently serving
#   .stable-history  — last N stable SHAs (rollback window)
# A SHA is deleted only if it is absent from ALL of the above.
set -euo pipefail

CDN_ACCOUNT_NAME="${CDN_ACCOUNT_NAME:?CDN_ACCOUNT_NAME is required}"
CDN_CONTAINER="${CDN_CONTAINER:?CDN_CONTAINER is required}"
# BLOB_PREFIX is resolved by the cdn-cleanup action via cdn-resolve-prefix
# (<repo>, or <ns>/<repo> when namespaced).
if [ -z "${BLOB_PREFIX+x}" ]; then
  echo "ERROR: BLOB_PREFIX must be set; run via the cdn-cleanup action" >&2
  exit 1
fi
LATEST_SHA="${LATEST_SHA:?LATEST_SHA is required}"
KEEP_STABLE="${KEEP_STABLE:-5}"
KEEP_RECENT="${KEEP_RECENT:-5}"

# Enforce a hard minimum of 5 so callers cannot shrink the protection window
# below a safe floor.
if [ "$KEEP_STABLE" -lt 5 ] 2>/dev/null; then
  echo "::warning::keep_stable=${KEEP_STABLE} is below the minimum of 5; clamping to 5"
  KEEP_STABLE=5
fi
if [ "$KEEP_RECENT" -lt 5 ] 2>/dev/null; then
  echo "::warning::keep_recent=${KEEP_RECENT} is below the minimum of 5; clamping to 5"
  KEEP_RECENT=5
fi

if [ -n "${CDN_SAS_TOKEN:-}" ]; then
  export AZURE_STORAGE_ACCOUNT="$CDN_ACCOUNT_NAME"
  export AZURE_STORAGE_SAS_TOKEN="$CDN_SAS_TOKEN"
fi

STABLE_HISTORY_BLOB="${BLOB_PREFIX:+$BLOB_PREFIX/}.stable-history"
LATEST_HISTORY_BLOB="${BLOB_PREFIX:+$BLOB_PREFIX/}.latest-history"
LATEST_CURRENT_BLOB="${BLOB_PREFIX:+$BLOB_PREFIX/}.latest-current"
STABLE_CURRENT_BLOB="${BLOB_PREFIX:+$BLOB_PREFIX/}.stable-current"
TMP=$(mktemp)
LIST_TMP=$(mktemp)
HIST_TMP=$(mktemp)
trap 'rm -f "$TMP" "$LIST_TMP" "$HIST_TMP" "${HIST_TMP}.new"' EXIT
protected=("$LATEST_SHA")

# Write the .latest-current pointer (single line) so operators can see which
# SHA the latest environment is transitioning to.
echo "$LATEST_SHA" > "$TMP"
if ! az storage blob upload \
  --container-name "$CDN_CONTAINER" \
  --file "$TMP" \
  --name "$LATEST_CURRENT_BLOB" \
  --overwrite >/dev/null; then
  echo "::warning::failed to upload .latest-current pointer"
fi

# Update .latest-history (rolling list of last N latest SHAs). Download the
# existing list, prepend the current SHA, dedupe, trim, and upload — all
# before any deletion so every SHA in the list is protected.
latest_hist_downloaded=0
if az storage blob exists \
  --container-name "$CDN_CONTAINER" \
  --name "$LATEST_HISTORY_BLOB" \
  --query exists -o tsv 2>/dev/null | grep -q '^true$'; then
  if az storage blob download \
    --container-name "$CDN_CONTAINER" \
    --name "$LATEST_HISTORY_BLOB" \
    --file "$HIST_TMP" 2>/dev/null; then
    latest_hist_downloaded=1
  fi
fi
{
  echo "$LATEST_SHA"
  if [ "$latest_hist_downloaded" -eq 1 ]; then cat "$HIST_TMP"; fi
} | awk 'NF && !seen[$0]++' | head -n "$KEEP_RECENT" > "${HIST_TMP}.new"
mv "${HIST_TMP}.new" "$HIST_TMP"
if ! az storage blob upload \
  --container-name "$CDN_CONTAINER" \
  --file "$HIST_TMP" \
  --name "$LATEST_HISTORY_BLOB" \
  --overwrite >/dev/null; then
  echo "::warning::failed to upload .latest-history; continuing with in-memory copy"
fi
mapfile -t latest_shas < "$HIST_TMP"
for sha in "${latest_shas[@]}"; do
  [[ -n "$sha" ]] && protected+=("$sha")
done

# Read .stable-current pointer (written by the stable-release workflow).
if az storage blob exists \
  --container-name "$CDN_CONTAINER" \
  --name "$STABLE_CURRENT_BLOB" \
  --query exists -o tsv 2>/dev/null | grep -q '^true$'; then
  if az storage blob download \
    --container-name "$CDN_CONTAINER" \
    --name "$STABLE_CURRENT_BLOB" \
    --file "$TMP" 2>/dev/null; then
    stable_current="$(head -1 "$TMP")"
    if [ -n "$stable_current" ]; then
      protected+=("$stable_current")
    fi
  fi
fi

# Read .stable-history (rollback window of last N stable SHAs). Abort if the
# existence check fails or the blob exists but cannot be downloaded — never
# risk deleting stable assets due to a transient outage.
history_exists_output=$(az storage blob exists \
  --container-name "$CDN_CONTAINER" \
  --name "$STABLE_HISTORY_BLOB" \
  --query exists -o tsv 2>/dev/null)
history_exists_exit=$?
if [ "$history_exists_exit" -ne 0 ]; then
  echo "ERROR: failed to check existence of history blob ${STABLE_HISTORY_BLOB}; aborting cleanup" >&2
  exit 1
fi
if [ "$history_exists_output" = "true" ]; then
  if ! az storage blob download \
    --container-name "$CDN_CONTAINER" \
    --name "$STABLE_HISTORY_BLOB" \
    --file "$TMP" 2>/dev/null; then
    echo "ERROR: failed to download history blob ${STABLE_HISTORY_BLOB}; aborting cleanup to avoid deleting stable assets" >&2
    exit 1
  fi
  mapfile -t stable_shas < <(head -n "$KEEP_STABLE" "$TMP")
  for sha in "${stable_shas[@]}"; do
    [[ -n "$sha" ]] && protected+=("$sha")
  done
fi

echo "Protected SHAs: ${protected[*]}"

list_prefix="${BLOB_PREFIX:+$BLOB_PREFIX/}"
if ! az storage blob list \
  --container-name "$CDN_CONTAINER" \
  --prefix "$list_prefix" \
  --query "[?starts_with(name, '${list_prefix}')].name" -o tsv > "$LIST_TMP" 2>/dev/null; then
  echo "ERROR: failed to list blobs under ${list_prefix}" >&2
  exit 1
fi

mapfile -t all_shas < <(
  cat "$LIST_TMP" \
    | sed "s#^${list_prefix}##" \
    | cut -d'/' -f1 \
    | sort -u
)

fail=0
for sha in "${all_shas[@]}"; do
  # Skip metadata blobs (anything starting with a dot).
  if [[ "$sha" == .* ]]; then
    continue
  fi

  if printf '%s\n' "${protected[@]}" | grep -qx "$sha"; then
    echo "KEEP  $sha"
    continue
  fi

  echo "DELETE $sha"
  delete_pattern="${BLOB_PREFIX:+$BLOB_PREFIX/}$sha/*"
  if ! az storage blob delete-batch \
    --source "$CDN_CONTAINER" \
    --pattern "$delete_pattern" >/dev/null; then
    echo "ERROR: failed to delete $sha" >&2
    fail=1
  fi
done

exit "$fail"
