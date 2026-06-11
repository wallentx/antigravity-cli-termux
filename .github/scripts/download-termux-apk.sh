#!/usr/bin/env bash
set -Eeuo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"

termux_channel="${TERMUX_CHANNEL:-stable}"

case "$termux_channel" in
  stable | latest) ;;
  *)
    echo "TERMUX_CHANNEL must be 'stable' or 'latest', got '$termux_channel'." >&2
    exit 1
    ;;
esac

echo "Fetching Termux app releases for channel: $termux_channel"
gh api repos/termux/termux-app/releases > termux-releases.json

if ! selected="$(
  jq -er --arg channel "$termux_channel" '
    [
      to_entries[]
      | .key as $release_index
      | .value
      | select(.draft == false)
      | select($channel != "stable" or .prerelease == false)
      | . as $release
      | $release.assets[]
      | . as $asset
      | (
          if ($asset.name | test("apt-android-7.*github-debug_universal\\.apk$")) then 0
          elif ($asset.name | test("\\+github-debug_universal\\.apk$")) then 1
          elif (
            ($asset.name | test("github-debug_universal\\.apk$")) and
            (($asset.name | test("apt-android-5")) | not)
          ) then 2
          else null
          end
        ) as $priority
      | select($priority != null)
      | {
          release_index: $release_index,
          priority: $priority,
          tag_name: $release.tag_name,
          name: $asset.name,
          url: $asset.browser_download_url
        }
    ]
    | sort_by(.release_index, .priority)
    | .[0]
    | [.tag_name, .name, .url]
    | @tsv
  ' termux-releases.json
)"; then
  echo "No matching Termux GitHub-debug universal APK was found." >&2
  exit 1
fi

IFS=$'\t' read -r release_tag apk_name apk_url <<< "$selected"

echo "Selected Termux release: $release_tag"
echo "Selected Termux APK: $apk_name"
echo "Downloading $apk_url"
curl --fail --location --retry 3 --retry-delay 5 "$apk_url" --output termux.apk

{
  printf 'TERMUX_CHANNEL=%s\n' "$termux_channel"
  printf 'TERMUX_RELEASE_TAG=%s\n' "$release_tag"
  printf 'TERMUX_APK_NAME=%s\n' "$apk_name"
  printf 'TERMUX_APK_URL=%s\n' "$apk_url"
} >> "$GITHUB_ENV"
