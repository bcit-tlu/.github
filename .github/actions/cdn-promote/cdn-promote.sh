#!/usr/bin/env bash
# Promote <content_ref>/* from the latest CDN account to the stable account.
#
#   1. Resolve the content ref — either directly via CONTENT_REF (manual escape hatch), or by waiting for .by-commit/<commit_sha> on the latest container (release-please fires the release on the same push that starts the latest-channel build, so the lookup can lag by minutes).
#   2. Enumerate the source prefix; an empty prefix means the ref was already pruned from latest — fail rather than promote nothing.
#   3. Server-side copy each blob across accounts (skipping destinations whose copy already succeeded — the stable account's immutability window makes redundant copies wasteful), poll each destination blob until its copy status is 'success', and finally require the destination name set to equal the source set so an interrupted earlier run can never pass as done.
#
# Auth: --auth-mode login throughout. The job's identity (the stable channel UAMI) holds Blob Data Reader on the latest container — needed to read .by-commit and to list the source prefix — and Blob Data Contributor on the stable container.
# The server-side copy itself fetches the source over anonymous read (the containers allow public blob access).
set -euo pipefail

LATEST_ACCOUNT="${LATEST_ACCOUNT:?LATEST_ACCOUNT is required}"
STABLE_ACCOUNT="${STABLE_ACCOUNT:?STABLE_ACCOUNT is required}"
CDN_CONTAINER="${CDN_CONTAINER:?CDN_CONTAINER is required}"
COMMIT_SHA="${COMMIT_SHA:-}"
CONTENT_REF="${CONTENT_REF:-}"
COPY_TIMEOUT="${COPY_TIMEOUT:-300}"
LOOKUP_TIMEOUT="${LOOKUP_TIMEOUT:-900}"

if [ -z "${COMMIT_SHA}" ] && [ -z "${CONTENT_REF}" ]; then
  echo "::error::Either COMMIT_SHA (resolved via .by-commit) or CONTENT_REF (direct promote) is required." >&2
  exit 1
fi

AUTH=(--auth-mode login)
TMP=$(mktemp)
SRC_LIST=$(mktemp)
DST_LIST=$(mktemp)
trap 'rm -f "$TMP" "$SRC_LIST" "$DST_LIST"' EXIT

if [ -z "${CONTENT_REF}" ]; then
# --- resolve the commit's content ref (with wait) -----------------------------
LOOKUP_BLOB=".by-commit/${COMMIT_SHA}"
lookup_deadline=$((SECONDS + LOOKUP_TIMEOUT))
while :; do
  if az storage blob exists \
      --account-name "$LATEST_ACCOUNT" \
      --container-name "$CDN_CONTAINER" \
      "${AUTH[@]}" \
      --name "$LOOKUP_BLOB" \
      --query exists -o tsv 2>/dev/null | grep -q '^true$'; then
    break
  fi
  if [ $SECONDS -ge $lookup_deadline ]; then
    echo "::error::No lookup blob ${LOOKUP_BLOB} in ${LATEST_ACCOUNT}/${CDN_CONTAINER} after ${LOOKUP_TIMEOUT}s." >&2
    echo "::error::The release tag's commit never produced a completed latest-channel build (or predates .by-commit). Push the commit to main and let ci finish first — or re-run with content_ref set to the known prefix." >&2
    exit 1
  fi
  echo "Waiting for ${LOOKUP_BLOB} (latest-channel build may still be running)..."
  sleep 30
done

az storage blob download \
  --account-name "$LATEST_ACCOUNT" \
  --container-name "$CDN_CONTAINER" \
  "${AUTH[@]}" \
  --name "$LOOKUP_BLOB" \
  --file "$TMP" >/dev/null
CONTENT_REF="$(head -1 "$TMP" | tr -d '[:space:]')"
echo "Resolved ${COMMIT_SHA} -> content ref ${CONTENT_REF}"
fi

if [[ ! "$CONTENT_REF" =~ ^[0-9a-f]{7,64}$ ]]; then
  echo "::error::Not a hex content ref (got '${CONTENT_REF}')" >&2
  exit 1
fi

# --- enumerate the source prefix (no --num-results: az follows continuation tokens) ---
if ! az storage blob list \
    --account-name "$LATEST_ACCOUNT" \
    --container-name "$CDN_CONTAINER" \
    "${AUTH[@]}" \
    --prefix "${CONTENT_REF}/" \
    --query "[].name" -o tsv | sort > "$SRC_LIST" 2>/dev/null; then
  echo "::error::Failed to list ${LATEST_ACCOUNT}/${CDN_CONTAINER}/${CONTENT_REF}/" >&2
  exit 1
fi
mapfile -t src_blobs < "$SRC_LIST"
src_count=${#src_blobs[@]}

if [ "$src_count" -eq 0 ]; then
  echo "::error::${LATEST_ACCOUNT}/${CDN_CONTAINER}/${CONTENT_REF}/ is empty — the prefix was pruned from latest (release is older than the latest retention window). Nothing to promote." >&2
  exit 1
fi
echo "Copying ${src_count} blobs: ${LATEST_ACCOUNT}/${CDN_CONTAINER}/${CONTENT_REF}/ -> ${STABLE_ACCOUNT}/${CDN_CONTAINER}/"

# Snapshot the destination prefix: blobs whose copy already succeeded are skipped, so a retried promotion doesn't write redundant versions into the immutable stable account.
az storage blob list \
  --account-name "$STABLE_ACCOUNT" \
  --container-name "$CDN_CONTAINER" \
  "${AUTH[@]}" \
  --prefix "${CONTENT_REF}/" \
  --query "[].name" -o tsv 2>/dev/null | sort > "$DST_LIST" || true

# --- server-side copy, one job per blob so each can be polled deterministically
for name in "${src_blobs[@]}"; do
  if grep -qxF "$name" "$DST_LIST"; then
    dest_status=$(az storage blob show \
      --account-name "$STABLE_ACCOUNT" \
      --container-name "$CDN_CONTAINER" \
      "${AUTH[@]}" \
      --name "$name" \
      --query "properties.copy.status" -o tsv 2>/dev/null || echo "")
    if [ "$dest_status" = "success" ]; then
      echo "SKIP  $name (already promoted)"
      continue
    fi
  fi
  az storage blob copy start \
    --account-name "$STABLE_ACCOUNT" \
    --destination-container "$CDN_CONTAINER" \
    --destination-blob "$name" \
    --source-account-name "$LATEST_ACCOUNT" \
    --source-container "$CDN_CONTAINER" \
    --source-blob "$name" \
    "${AUTH[@]}" >/dev/null
done

# --- poll every destination blob to 'success' ---------------------------------
copy_deadline=$((SECONDS + COPY_TIMEOUT))
for name in "${src_blobs[@]}"; do
  while :; do
    status=$(az storage blob show \
      --account-name "$STABLE_ACCOUNT" \
      --container-name "$CDN_CONTAINER" \
      "${AUTH[@]}" \
      --name "$name" \
      --query "properties.copy.status" -o tsv 2>/dev/null || echo "error")
    if [ "$status" = "success" ]; then
      break
    fi
    if [ "$status" = "aborted" ] || [ "$status" = "failed" ] || [ "$status" = "error" ]; then
      echo "::error::Copy of ${name} ended with status '${status}'" >&2
      exit 1
    fi
    if [ $SECONDS -ge $copy_deadline ]; then
      echo "::error::Timed out waiting for copy of ${name} (status '${status}')" >&2
      exit 1
    fi
    sleep 2
  done
done

# --- final integrity check: destination name set must equal the source set ----
az storage blob list \
  --account-name "$STABLE_ACCOUNT" \
  --container-name "$CDN_CONTAINER" \
  "${AUTH[@]}" \
  --prefix "${CONTENT_REF}/" \
  --query "[].name" -o tsv 2>/dev/null | sort > "$DST_LIST" || true
if ! diff -q "$SRC_LIST" "$DST_LIST" >/dev/null; then
  echo "::error::Promoted prefix differs from source — missing: $(comm -23 "$SRC_LIST" "$DST_LIST" | wc -l), extra: $(comm -13 "$SRC_LIST" "$DST_LIST" | wc -l). Promotion is incomplete." >&2
  exit 1
fi

echo "Promoted ${CONTENT_REF}/ (${src_count} blobs) to ${STABLE_ACCOUNT}/${CDN_CONTAINER}."
echo "content_ref=${CONTENT_REF}" >> "$GITHUB_OUTPUT"
