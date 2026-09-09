#!/usr/bin/env bash
# Delete unreferenced CDN SHA prefixes, keeping the current latest SHA and the
# last N stable SHAs recorded in blob storage.
set -euo pipefail

CDN_ACCOUNT_NAME="${CDN_ACCOUNT_NAME:?CDN_ACCOUNT_NAME is required}"
CDN_CONTAINER="${CDN_CONTAINER:?CDN_CONTAINER is required}"
# BLOB_PREFIX is resolved by the cdn-cleanup action via cdn-resolve-prefix
# (empty string = SHAs live at the container root).
if [ -z "${BLOB_PREFIX+x}" ]; then
  echo "ERROR: BLOB_PREFIX must be set (empty string allowed); run via the cdn-cleanup action" >&2
  exit 1
fi
LATEST_SHA="${LATEST_SHA:?LATEST_SHA is required}"
KEEP_STABLE="${KEEP_STABLE:-5}"

if [ -n "${CDN_SAS_TOKEN:-}" ]; then
  export AZURE_STORAGE_ACCOUNT="$CDN_ACCOUNT_NAME"
  export AZURE_STORAGE_SAS_TOKEN="$CDN_SAS_TOKEN"
fi

HISTORY_BLOB="${BLOB_PREFIX:+$BLOB_PREFIX/}.stable-history"
TMP=$(mktemp)
LIST_TMP=$(mktemp)
trap 'rm -f "$TMP" "$LIST_TMP"' EXIT
protected=("$LATEST_SHA")

# Only read history if the blob exists. If the existence check itself fails or
# the blob exists but cannot be downloaded, abort rather than risk deleting
# stable assets.
history_exists_output=$(az storage blob exists \
  --container-name "$CDN_CONTAINER" \
  --name "$HISTORY_BLOB" \
  --query exists -o tsv 2>/dev/null)
history_exists_exit=$?
if [ "$history_exists_exit" -ne 0 ]; then
  echo "ERROR: failed to check existence of history blob ${HISTORY_BLOB}; aborting cleanup" >&2
  exit 1
fi

if [ "$history_exists_output" = "true" ]; then
  if ! az storage blob download \
    --container-name "$CDN_CONTAINER" \
    --name "$HISTORY_BLOB" \
    --file "$TMP" 2>/dev/null; then
    echo "ERROR: failed to download history blob ${HISTORY_BLOB}; aborting cleanup to avoid deleting stable assets" >&2
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
  [[ "$sha" == ".stable-history" ]] && continue

  if printf '%s\n' "${protected[@]}" | grep -qx "$sha"; then
    echo "KEEP  $sha"
  else
    echo "DELETE $sha"
    delete_pattern="${BLOB_PREFIX:+$BLOB_PREFIX/}$sha/*"
    if ! az storage blob delete-batch \
      --source "$CDN_CONTAINER" \
      --pattern "$delete_pattern" >/dev/null; then
      echo "ERROR: failed to delete $sha" >&2
      fail=1
    fi
  fi
done

exit "$fail"
