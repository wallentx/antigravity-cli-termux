#!/usr/bin/env bash
set -Eeuo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${TERMUX_APK_URL:?TERMUX_APK_URL is required}"
: "${TERMUX_HOME:?TERMUX_HOME is required}"
: "${TERMUX_PREFIX:?TERMUX_PREFIX is required}"

bootstrap_attempts="${TERMUX_BOOTSTRAP_ATTEMPTS:-240}"
bootstrap_interval_seconds="${TERMUX_BOOTSTRAP_INTERVAL_SECONDS:-2}"
if ! [[ "$bootstrap_attempts" =~ ^[0-9]+$ && "$bootstrap_interval_seconds" =~ ^[0-9]+$ ]]; then
  echo "TERMUX_BOOTSTRAP_ATTEMPTS and TERMUX_BOOTSTRAP_INTERVAL_SECONDS must be positive integers." >&2
  exit 1
fi

probe_file=termux-emulator-probe.env
: > "$probe_file"
trap 'adb logcat -d > termux-emulator-logcat.txt 2>/dev/null || true' EXIT

log() {
  printf '[termux-probe] %s\n' "$*"
}

record() {
  printf '%s=%s\n' "$1" "$2" | tee -a "$probe_file"
}

run_as_termux_shell() {
  local command_line=$1

  if [[ "$command_line" == *"'"* ]]; then
    echo "run_as_termux_shell does not accept single quotes in command text." >&2
    return 1
  fi

  adb shell "run-as com.termux sh -c '$command_line'"
}

termux_exec() {
  local command_line=$1
  local local_script
  local remote_tmp=/data/local/tmp/termux-probe-command.sh
  local remote_script="$TERMUX_HOME/.termux-probe-command.sh"

  local_script=$(mktemp "${RUNNER_TEMP:-.}/termux-command.XXXXXX")
  {
    printf '#!%s/bin/bash\n' "$TERMUX_PREFIX"
    printf 'set -Eeuo pipefail\n'
    printf 'export HOME=%q\n' "$TERMUX_HOME"
    printf 'export PREFIX=%q\n' "$TERMUX_PREFIX"
    printf 'export TMPDIR=%q\n' "$TERMUX_PREFIX/tmp"
    printf 'export TERMUX_VERSION=ci\n'
    printf 'export PATH=%q\n' "$TERMUX_PREFIX/bin:/system/bin:/system/xbin"
    printf "mkdir -p \"\$TMPDIR\"\n"
    printf "cd \"\$HOME\"\n"
    printf '%s\n' "$command_line"
  } > "$local_script"

  if ! adb push "$local_script" "$remote_tmp" >/dev/null; then
    rm -f "$local_script"
    return 1
  fi

  if ! run_as_termux_shell "cp $remote_tmp $remote_script && chmod 700 $remote_script && $TERMUX_PREFIX/bin/bash $remote_script"; then
    rm -f "$local_script"
    return 1
  fi

  rm -f "$local_script"
}

dump_termux_state() {
  local label=$1

  log "Diagnostics: $label"
  adb shell pidof com.termux 2>/dev/null | sed 's/^/[termux-probe] com.termux pid: /' || true
  adb shell dumpsys package com.termux 2>/dev/null \
    | grep -E 'versionName|versionCode|primaryCpuAbi|secondaryCpuAbi|dataDir' \
    | sed 's/^/[termux-probe] package: /' || true
  run_as_termux_shell 'pwd; id; ls -la files files/usr files/usr/bin 2>&1' \
    | sed 's/^/[termux-probe] run-as: /' || true
}

install_termux_packages() {
  log "Installing Termux packages: ca-certificates glibc-repo glibc-runner"
  termux_exec '
pkg update -y
pkg install ca-certificates glibc-repo -y
pkg install glibc-runner -y
'
  record TERMUX_PACKAGES_INSTALLED "ca-certificates glibc-repo glibc-runner"
}

run_extra_termux_commands() {
  local phase=$1

  if [[ -z "${TERMUX_EXTRA_COMMANDS:-}" ]]; then
    return 0
  fi

  log "Running additional Termux commands at $phase."
  termux_exec "$TERMUX_EXTRA_COMMANDS"
  record TERMUX_EXTRA_COMMANDS_RAN "$phase"
}

validate_release_tag() {
  local release_tag=$1

  if [[ -z "$release_tag" || "$release_tag" == -* || ! "$release_tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Release tag contains unsupported characters: $release_tag" >&2
    return 1
  fi
}

test_host_standalone_archive() {
  local host_archive=${TERMUX_STANDALONE_ARCHIVE:-}
  local archive_name=antigravity-termux-standalone.tar.gz

  if [[ -z "$host_archive" ]]; then
    return 0
  fi
  if [[ ! -f "$host_archive" ]]; then
    echo "Standalone archive path does not exist: $host_archive" >&2
    return 1
  fi

  log "Testing standalone archive from PR artifact: $host_archive"
  adb push "$host_archive" "/data/local/tmp/$archive_name" >/dev/null
  adb shell chmod 0644 "/data/local/tmp/$archive_name"
  run_as_termux_shell "cp /data/local/tmp/$archive_name $TERMUX_HOME/$archive_name"

  # shellcheck disable=SC2016
  termux_exec '
rm -rf "$HOME/agy-pr-artifact-smoke"
mkdir -p "$HOME/agy-pr-artifact-smoke"
cd "$HOME/agy-pr-artifact-smoke"
cp "$HOME/antigravity-termux-standalone.tar.gz" .
tar -xzf antigravity-termux-standalone.tar.gz
./bin/agy --help
'
  record TERMUX_PR_ARTIFACT_SMOKE "passed"
}

test_release_standalone_archive() {
  local release_tag=${TERMUX_RELEASE_TEST_TAG:-}

  if [[ -z "$release_tag" ]]; then
    return 0
  fi

  validate_release_tag "$release_tag"
  log "Testing standalone release artifact: $release_tag"

  termux_exec "
rm -rf \"\$HOME/agy-release-smoke\"
mkdir -p \"\$HOME/agy-release-smoke\"
cd \"\$HOME/agy-release-smoke\"
curl -fsSLO https://github.com/wallentx/antigravity-cli-termux/releases/download/$release_tag/antigravity-termux-standalone.tar.gz
tar -xzf antigravity-termux-standalone.tar.gz
./bin/agy --help
"
  record TERMUX_RELEASE_ARTIFACT_SMOKE "$release_tag"
}

wait_for_termux_bootstrap() {
  local attempt

  log "Waiting for Termux bootstrap: $bootstrap_attempts attempts, ${bootstrap_interval_seconds}s interval"
  for ((attempt = 1; attempt <= bootstrap_attempts; attempt++)); do
    if run_as_termux_shell 'test -x files/usr/bin/bash' >/dev/null 2>&1; then
      log "Termux bootstrap completed after attempt $attempt."
      return 0
    fi

    if ((attempt == 1 || attempt % 30 == 0)); then
      dump_termux_state "bootstrap wait attempt $attempt/$bootstrap_attempts"
    fi

    sleep "$bootstrap_interval_seconds"
  done

  return 1
}

log "Starting Termux emulator probe."
device_abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
device_abilist=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')
record ANDROID_CPU_ABI "$device_abi"
record ANDROID_CPU_ABILIST "$device_abilist"
record TERMUX_CHANNEL "${TERMUX_CHANNEL:-unknown}"
record TERMUX_RELEASE_TAG "${TERMUX_RELEASE_TAG:-unknown}"
record TERMUX_APK_NAME "${TERMUX_APK_NAME:-unknown}"
record TERMUX_APK_URL "$TERMUX_APK_URL"
record TERMUX_BOOTSTRAP_ATTEMPTS "$bootstrap_attempts"
record TERMUX_BOOTSTRAP_INTERVAL_SECONDS "$bootstrap_interval_seconds"
record TERMUX_RESTORE_SNAPSHOT "${TERMUX_RESTORE_SNAPSHOT:-false}"
record TERMUX_SAVE_SNAPSHOT "${TERMUX_SAVE_SNAPSHOT:-false}"
record TERMUX_AVD_CACHE_PREFIX "${TERMUX_AVD_CACHE_PREFIX:-unknown}"
record TERMUX_AVD_CACHE_KEY "${TERMUX_AVD_CACHE_KEY:-unknown}"
record TERMUX_STANDALONE_ARCHIVE "${TERMUX_STANDALONE_ARCHIVE:-none}"
record TERMUX_PR_SOURCE_RUN_ID "${TERMUX_PR_SOURCE_RUN_ID:-none}"
record TERMUX_RELEASE_TEST_TAG "${TERMUX_RELEASE_TEST_TAG:-none}"
record TERMUX_EXTRA_COMMANDS_PRESENT "$([[ -n "${TERMUX_EXTRA_COMMANDS:-}" ]] && echo true || echo false)"
record TERMUX_EXTRA_COMMANDS_AT_START "${TERMUX_EXTRA_COMMANDS_AT_START:-false}"

log "Installing Termux APK: ${TERMUX_APK_NAME:-unknown}"
adb install -r termux.apk
adb shell pm grant com.termux android.permission.POST_NOTIFICATIONS || true
log "Launching Termux."
adb shell monkey -p com.termux -c android.intent.category.LAUNCHER 1 >/dev/null

if ! wait_for_termux_bootstrap; then
  dump_termux_state "bootstrap timeout"
  echo "Termux did not finish bootstrap within the timeout." >&2
  exit 1
fi

log "Validating Termux command environment."
termux_exec_pwd=$(termux_exec 'pwd' | tr -d '\r')
termux_exec_id=$(termux_exec 'id' | tr -d '\r')
termux_exec_path=$(termux_exec "printf '%s\n' \"\$PATH\"" | tr -d '\r')
termux_pkg_path=$(termux_exec 'command -v pkg' | tr -d '\r')

record TERMUX_EXEC_PWD "$termux_exec_pwd"
record TERMUX_EXEC_ID "$termux_exec_id"
record TERMUX_EXEC_PATH "$termux_exec_path"
record TERMUX_PKG_PATH "$termux_pkg_path"

if [[ "${TERMUX_EXTRA_COMMANDS_AT_START:-false}" == "true" ]]; then
  run_extra_termux_commands start
fi

install_termux_packages

if [[ "${TERMUX_EXTRA_COMMANDS_AT_START:-false}" != "true" ]]; then
  run_extra_termux_commands end
fi

log "Collecting Termux runtime details."
termux_arch=$(termux_exec 'uname -m' | tr -d '\r')
termux_dpkg_arch=$(termux_exec 'dpkg --print-architecture 2>/dev/null || true' | tr -d '\r')
termux_loader_state=$(termux_exec 'test -e /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 && echo present || echo missing' | tr -d '\r')

record TERMUX_UNAME_M "$termux_arch"
record TERMUX_DPKG_ARCH "$termux_dpkg_arch"
record TERMUX_AARCH64_GLIBC_LOADER "$termux_loader_state"

test_host_standalone_archive
test_release_standalone_archive

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

log "Running aarch64 release smoke test."
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
