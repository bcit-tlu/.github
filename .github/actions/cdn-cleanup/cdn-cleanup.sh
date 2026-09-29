#!/usr/bin/env bash
# Delete unreferenced CDN ref prefixes. Protection is deterministic:
#   .latest-current  — the ref the latest environment is transitioning to
#   .latest-history  — last N latest refs (rollout-lag + rollback window)
#   .stable-current  — the ref the stable environment is currently serving
#   .stable-history  — last N stable refs (rollback window)
# A ref (content hash) is deleted only if it is absent from ALL of the above.
# Dot-prefixed blobs (.by-commit/* lookups, pointers, journals) are skipped.
#
# CHANNEL selects the per-channel pointer behaviour for deployments where each environment has its own storage account (e.g. bcitcdnlatest / bcitcdnstable): 'latest' also writes the .latest-* pointers; 'stable' only reads pointers (cdn-stable-history owns stable pointer writes).
# Empty CHANNEL preserves the legacy single-container behaviour.
set -euo pipefail

CDN_ACCOUNT_NAME="${CDN_ACCOUNT_NAME:?CDN_ACCOUNT_NAME is required}"
CDN_CONTAINER="${CDN_CONTAINER:?CDN_CONTAINER is required}"
SERVE_REF="${SERVE_REF:?SERVE_REF is required}"
CHANNEL="${CHANNEL:-}"
IMMUTABLE_DAYS="${IMMUTABLE_DAYS:-0}"
KEEP_STABLE="${KEEP_STABLE:-5}"
KEEP_RECENT="${KEEP_RECENT:-5}"

# IMMUTABLE_DAYS > 0 means the account enforces time-based immutability (e.g. the stable CDN account's 90-day policy): deletes of younger blobs would be rejected, so refs inside the window are skipped and retried once aged out.
if ! [[ "${IMMUTABLE_DAYS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: IMMUTABLE_DAYS must be a non-negative integer (got '${IMMUTABLE_DAYS}')" >&2
  exit 1
fi

# Reject unknown channels: anything non-'stable' below writes .latest-* pointers, so a typo would silently pollute the wrong account's journals.
case "${CHANNEL}" in
  ""|latest|stable) ;;
  *)
    echo "ERROR: CHANNEL must be 'latest', 'stable', or empty (got '${CHANNEL}')" >&2
    exit 1
    ;;
esac

# Enforce a hard minimum of 5 so callers cannot shrink the protection window below a safe floor.
if [ "$KEEP_STABLE" -lt 5 ] 2>/dev/null; then
  echo "::warning::keep_stable=${KEEP_STABLE} is below the minimum of 5; clamping to 5"
  KEEP_STABLE=5
fi
if [ "$KEEP_RECENT" -lt 5 ] 2>/dev/null; then
  echo "::warning::keep_recent=${KEEP_RECENT} is below the minimum of 5; clamping to 5"
  KEEP_RECENT=5
fi

export AZURE_STORAGE_ACCOUNT="$CDN_ACCOUNT_NAME"
AUTH_ARGS=()
if [ -n "${CDN_SAS_TOKEN:-}" ]; then
  export AZURE_STORAGE_SAS_TOKEN="$CDN_SAS_TOKEN"
else
  # No SAS token — assume the job authenticated via azure/login (OIDC UAMI).
  AUTH_ARGS+=(--auth-mode login)
fi

STABLE_HISTORY_BLOB=".stable-history"
LATEST_HISTORY_BLOB=".latest-history"
LATEST_CURRENT_BLOB=".latest-current"
STABLE_CURRENT_BLOB=".stable-current"
TMP=$(mktemp)
LIST_TMP=$(mktemp)
HIST_TMP=$(mktemp)
trap 'rm -f "$TMP" "$LIST_TMP" "$HIST_TMP" "${HIST_TMP}.new"' EXIT
protected=("$SERVE_REF")

if [ "${CHANNEL}" != "stable" ]; then
# Write the .latest-current pointer (single line) so operators can see which ref the latest environment is transitioning to.
echo "$SERVE_REF" > "$TMP"
if ! az storage blob upload \
  --container-name "$CDN_CONTAINER" \
    "${AUTH_ARGS[@]}" \
  --file "$TMP" \
  --name "$LATEST_CURRENT_BLOB" \
  --overwrite >/dev/null; then
  echo "::warning::failed to upload .latest-current pointer"
fi

# Update .latest-history (rolling list of last N latest refs). Download the existing list, prepend the current ref, dedupe, trim, and upload — all before any deletion so every ref in the list is protected.
latest_hist_downloaded=0
if az storage blob exists \
  --container-name "$CDN_CONTAINER" \
    "${AUTH_ARGS[@]}" \
  --name "$LATEST_HISTORY_BLOB" \
  --query exists -o tsv 2>/dev/null | grep -q '^true$'; then
  if az storage blob download \
    --container-name "$CDN_CONTAINER" \
    "${AUTH_ARGS[@]}" \
    --name "$LATEST_HISTORY_BLOB" \
    --file "$HIST_TMP" 2>/dev/null; then
    latest_hist_downloaded=1
  fi
fi
{
  echo "$SERVE_REF"
  if [ "$latest_hist_downloaded" -eq 1 ]; then cat "$HIST_TMP"; fi
} | awk 'NF && !seen[$0]++' | head -n "$KEEP_RECENT" > "${HIST_TMP}.new"
mv "${HIST_TMP}.new" "$HIST_TMP"
if ! az storage blob upload \
  --container-name "$CDN_CONTAINER" \
    "${AUTH_ARGS[@]}" \
  --file "$HIST_TMP" \
  --name "$LATEST_HISTORY_BLOB" \
  --overwrite >/dev/null; then
  echo "::warning::failed to upload .latest-history; continuing with in-memory copy"
fi
mapfile -t latest_refs < "$HIST_TMP"
for ref in "${latest_refs[@]}"; do
  [[ -n "$ref" ]] && protected+=("$ref")
done
fi

# Read .stable-current pointer (written by the stable-release workflow).
if az storage blob exists \
  --container-name "$CDN_CONTAINER" \
    "${AUTH_ARGS[@]}" \
  --name "$STABLE_CURRENT_BLOB" \
  --query exists -o tsv 2>/dev/null | grep -q '^true$'; then
  if az storage blob download \
    --container-name "$CDN_CONTAINER" \
    "${AUTH_ARGS[@]}" \
    --name "$STABLE_CURRENT_BLOB" \
    --file "$TMP" 2>/dev/null; then
    stable_current="$(head -1 "$TMP")"
    if [ -n "$stable_current" ]; then
      protected+=("$stable_current")
    fi
  fi
fi

# Read .stable-history (rollback window of last N stable refs). Abort if the existence check fails or the blob exists but cannot be downloaded — never risk deleting stable assets due to a transient outage.
history_exists_output=$(az storage blob exists \
  --container-name "$CDN_CONTAINER" \
    "${AUTH_ARGS[@]}" \
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
    "${AUTH_ARGS[@]}" \
    --name "$STABLE_HISTORY_BLOB" \
    --file "$TMP" 2>/dev/null; then
    echo "ERROR: failed to download history blob ${STABLE_HISTORY_BLOB}; aborting cleanup to avoid deleting stable assets" >&2
    exit 1
  fi
  mapfile -t stable_refs < <(head -n "$KEEP_STABLE" "$TMP")
  for ref in "${stable_refs[@]}"; do
    [[ -n "$ref" ]] && protected+=("$ref")
  done
fi

echo "Protected refs: ${protected[*]}"

# List all top-level ref prefixes in the container, with creation time so the immutability window can be evaluated per prefix.
if ! az storage blob list \
  --container-name "$CDN_CONTAINER" \
    "${AUTH_ARGS[@]}" \
  --query "[].[name, properties.creationTime]" -o tsv > "$LIST_TMP" 2>/dev/null; then
  echo "ERROR: failed to list blobs in container ${CDN_CONTAINER}" >&2
  exit 1
fi

mapfile -t all_refs < <(cut -d'/' -f1 "$LIST_TMP" | cut -f1 | sort -u)

if [ "$IMMUTABLE_DAYS" -gt 0 ]; then
  immutable_cutoff=$(( $(date +%s) - IMMUTABLE_DAYS * 86400 ))
fi

fail=0
for ref in "${all_refs[@]}"; do
  # Skip metadata blobs (anything starting with a dot).
  if [[ "$ref" == .* ]]; then
    continue
  fi

  if printf '%s\n' "${protected[@]}" | grep -qx "$ref"; then
    echo "KEEP  $ref"
    continue
  fi

  # Skip prefixes still inside the account immutability window: a prefix is only deletable once its youngest blob is past the window; blob timestamps are UTC ISO8601 (fractional seconds trimmed for GNU date).
  if [ "$IMMUTABLE_DAYS" -gt 0 ]; then
    youngest="$(awk -F'\t' -v p="${ref}/" 'index($1, p) == 1 { print $2 }' "$LIST_TMP" | sort | tail -1)"
    youngest_epoch="$(date -u -d "${youngest:0:19}Z" +%s 2>/dev/null || echo 0)"
    if [ "$youngest_epoch" -gt "$immutable_cutoff" ]; then
      remaining=$(( (youngest_epoch - immutable_cutoff + 86399) / 86400 ))
      echo "SKIP  $ref (inside the ${IMMUTABLE_DAYS}d immutability window; deletable in ~${remaining}d)"
      continue
    fi
  fi

  echo "DELETE $ref"
  if ! az storage blob delete-batch \
    --source "$CDN_CONTAINER" \
    "${AUTH_ARGS[@]}" \
    --pattern "$ref/*" >/dev/null; then
    echo "ERROR: failed to delete $ref" >&2
    fail=1
  fi
done

exit "$fail"
