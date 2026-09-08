#!/usr/bin/env bash
# Delete unreferenced CDN SHA prefixes, keeping the current latest SHA and the
# last N stable SHAs recorded in blob storage.
set -euo pipefail

CDN_ACCOUNT_NAME="${CDN_ACCOUNT_NAME:?CDN_ACCOUNT_NAME is required}"
CDN_CONTAINER="${CDN_CONTAINER:?CDN_CONTAINER is required}"
CDN_NAMESPACE="${CDN_NAMESPACE:-}"
[ "$CDN_NAMESPACE" = "none" ] && CDN_NAMESPACE=""
REPO_NAME="${REPO_NAME:?REPO_NAME is required}"
LATEST_SHA="${LATEST_SHA:?LATEST_SHA is required}"

if [ -n "${CDN_SAS_TOKEN:-}" ]; then
  export AZURE_STORAGE_ACCOUNT="$CDN_ACCOUNT_NAME"
  export AZURE_STORAGE_SAS_TOKEN="$CDN_SAS_TOKEN"
fi

# The blob prefix is the path inside the storage container before the SHA.
# When the container name matches the repo/app name, the SHA sits at the root.
if [ -n "$CDN_NAMESPACE" ]; then
  BLOB_PREFIX="${CDN_NAMESPACE}/${REPO_NAME}"
elif [ "$CDN_CONTAINER" = "$REPO_NAME" ]; then
  BLOB_PREFIX=""
else
  BLOB_PREFIX="${REPO_NAME}"
fi

HISTORY_BLOB="${BLOB_PREFIX:+$BLOB_PREFIX/}.stable-history"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
protected=("$LATEST_SHA")

if az storage blob download \
  --container-name "$CDN_CONTAINER" \
  --name "$HISTORY_BLOB" \
  --file "$TMP" 2>/dev/null; then
  while IFS= read -r sha; do
    [[ -n "$sha" ]] && protected+=("$sha")
  done < "$TMP"
fi

echo "Protected SHAs: ${protected[*]}"

list_prefix="${BLOB_PREFIX:+$BLOB_PREFIX/}"
mapfile -t all_shas < <(
  az storage blob list \
    --container-name "$CDN_CONTAINER" \
    --prefix "$list_prefix" \
    --query "[?starts_with(name, '${list_prefix}')].name" -o tsv \
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
