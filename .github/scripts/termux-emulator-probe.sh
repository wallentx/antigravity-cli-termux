#!/usr/bin/env bash
set -Eeuo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${TERMUX_APK_URL:?TERMUX_APK_URL is required}"
: "${TERMUX_HOME:?TERMUX_HOME is required}"
: "${TERMUX_PREFIX:?TERMUX_PREFIX is required}"

probe_file=termux-emulator-probe.env
: > "$probe_file"
trap 'adb logcat -d > termux-emulator-logcat.txt 2>/dev/null || true' EXIT

record() {
  printf '%s=%s\n' "$1" "$2" | tee -a "$probe_file"
}

termux_exec() {
  local command_line=$1

  adb shell run-as com.termux env \
    "HOME=$TERMUX_HOME" \
    "PREFIX=$TERMUX_PREFIX" \
    "TMPDIR=$TERMUX_PREFIX/tmp" \
    "TERMUX_VERSION=ci" \
    "PATH=$TERMUX_PREFIX/bin:/system/bin:/system/xbin" \
    "$TERMUX_PREFIX/bin/bash" -lc "$command_line"
}

wait_for_termux_bootstrap() {
  local attempt

  for ((attempt = 1; attempt <= 120; attempt++)); do
    if adb shell run-as com.termux test -x files/usr/bin/bash >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

device_abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
device_abilist=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')
record ANDROID_CPU_ABI "$device_abi"
record ANDROID_CPU_ABILIST "$device_abilist"
record TERMUX_APK_URL "$TERMUX_APK_URL"

adb install -r termux.apk
adb shell pm grant com.termux android.permission.POST_NOTIFICATIONS || true
adb shell monkey -p com.termux -c android.intent.category.LAUNCHER 1 >/dev/null

if ! wait_for_termux_bootstrap; then
  echo "Termux did not finish bootstrap within the timeout." >&2
  exit 1
fi

termux_arch=$(termux_exec 'uname -m' | tr -d '\r')
termux_dpkg_arch=$(termux_exec 'dpkg --print-architecture 2>/dev/null || true' | tr -d '\r')
termux_loader_state=$(termux_exec 'test -e /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 && echo present || echo missing' | tr -d '\r')

record TERMUX_UNAME_M "$termux_arch"
record TERMUX_DPKG_ARCH "$termux_dpkg_arch"
record TERMUX_AARCH64_GLIBC_LOADER "$termux_loader_state"

{
  echo "### Termux Emulator Probe"
  echo ""
  echo "| Field | Value |"
  echo "| --- | --- |"
  # shellcheck disable=SC2016
  sed 's/|/\\|/g; s/^\([^=]*\)=\(.*\)$/| `\1` | `\2` |/' "$probe_file"
  echo ""
} >> "$GITHUB_STEP_SUMMARY"

if [[ "$termux_arch" != "aarch64" && "${REQUIRE_AARCH64:-false}" == "true" ]]; then
  echo "Termux reported $termux_arch, but require_aarch64 was enabled." >&2
  exit 1
fi

if [[ "$termux_arch" != "aarch64" ]]; then
  echo "Termux reported $termux_arch; skipping the v1.0.6 aarch64 release smoke test."
  exit 0
fi

cat > termux-release-smoke.sh <<'TERMUX_RELEASE_SMOKE'
set -euo pipefail

mkdir -p "$HOME/agy-smoke"
cd "$HOME/agy-smoke"

pkg update -y
pkg install ca-certificates glibc-repo -y
pkg install glibc-runner -y
curl -fsSLO https://github.com/wallentx/antigravity-cli-termux/releases/download/v1.0.6/antigravity-termux-standalone.tar.gz
tar -xzf antigravity-termux-standalone.tar.gz
./bin/agy --help
TERMUX_RELEASE_SMOKE

adb push termux-release-smoke.sh /data/local/tmp/termux-release-smoke.sh >/dev/null
adb shell chmod 0644 /data/local/tmp/termux-release-smoke.sh
termux_exec 'bash /data/local/tmp/termux-release-smoke.sh'
