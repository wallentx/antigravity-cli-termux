#!/usr/bin/env bash
set -Eeuo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${SOURCE_RUN_ID:?SOURCE_RUN_ID is required}"

artifact_name="${TERMUX_PR_ARTIFACT_NAME:-antigravity-termux-standalone-preview}"
artifact_dir="${TERMUX_PR_ARTIFACT_DIR:-termux-pr-artifact}"
archive_path="$artifact_dir/antigravity-termux-standalone.tar.gz"

rm -rf "$artifact_dir"
mkdir -p "$artifact_dir"

echo "Downloading artifact '$artifact_name' from workflow run $SOURCE_RUN_ID"
gh run download "$SOURCE_RUN_ID" \
  --repo "$GITHUB_REPOSITORY" \
  --name "$artifact_name" \
  --dir "$artifact_dir"

if [[ ! -f "$archive_path" ]]; then
  echo "Expected archive not found after artifact download: $archive_path" >&2
  find "$artifact_dir" -maxdepth 3 -type f -print >&2
  exit 1
fi

tar -tzf "$archive_path" | grep -qE '^bin/agy$' || {
  echo "Downloaded archive is missing bin/agy." >&2
  exit 1
}

tar -tzf "$archive_path" | grep -qE '^bin/agy\.va39$' || {
  echo "Downloaded archive is missing bin/agy.va39." >&2
  exit 1
}

printf 'TERMUX_STANDALONE_ARCHIVE=%s\n' "$archive_path" >> "$GITHUB_ENV"
printf 'TERMUX_PR_SOURCE_RUN_ID=%s\n' "$SOURCE_RUN_ID" >> "$GITHUB_ENV"
