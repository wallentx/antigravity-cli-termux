#!/usr/bin/env bash
set -Eeuo pipefail

: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${TERMUX_HOME:?TERMUX_HOME is required}"
: "${TERMUX_PREFIX:?TERMUX_PREFIX is required}"

bootstrap_attempts="${TERMUX_BOOTSTRAP_ATTEMPTS:-240}"
bootstrap_interval_seconds="${TERMUX_BOOTSTRAP_INTERVAL_SECONDS:-2}"
termux_install_abi="${TERMUX_INSTALL_ABI:-arm64-v8a}"
if ! [[ "$bootstrap_attempts" =~ ^[0-9]+$ && "$bootstrap_interval_seconds" =~ ^[0-9]+$ ]]; then
  echo "TERMUX_BOOTSTRAP_ATTEMPTS and TERMUX_BOOTSTRAP_INTERVAL_SECONDS must be positive integers." >&2
  exit 1
fi

probe_file=termux-emulator-probe.env
: > "$probe_file"

capture_termux_diagnostics() {
  adb logcat -d > termux-emulator-logcat.txt 2>/dev/null || true

  if ! adb devices | grep -q -E "\bdevice\b"; then
    return 0
  fi

  adb shell ps -A > termux-ps.txt 2>/dev/null || true
  adb shell dumpsys activity > termux-dumpsys-activity.txt 2>/dev/null || true
  adb shell dumpsys package com.termux > termux-dumpsys-package.txt 2>/dev/null || true
  adb shell run-as com.termux ls -la "$TERMUX_HOME" > termux-home-listing.txt 2>/dev/null || true

  local dir
  for dir in $(adb shell run-as com.termux find "$TERMUX_HOME/" -maxdepth 1 -name ".termux-probe-results-*" 2>/dev/null | tr -d '\r'); do
    if [[ -n "$dir" ]]; then
      local base
      base=$(basename "$dir")
      echo "=== Captured stdout for $base ===" > "termux-stdout-$base.txt"
      adb shell run-as com.termux cat "$dir/stdout" >> "termux-stdout-$base.txt" 2>/dev/null || true
      echo "=== Captured stderr for $base ===" > "termux-stderr-$base.txt"
      adb shell run-as com.termux cat "$dir/stderr" >> "termux-stderr-$base.txt" 2>/dev/null || true
      echo "=== Captured status for $base ===" > "termux-status-$base.txt"
      adb shell run-as com.termux cat "$dir/status" >> "termux-status-$base.txt" 2>/dev/null || true
    fi
  done
}
trap capture_termux_diagnostics EXIT

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
  local command_id
  local local_script
  local remote_tmp=/data/local/tmp/termux-probe-command.sh
  local remote_script
  local remote_result_dir
  local remote_stdout
  local remote_stderr
  local remote_status
  local attempt
  local status

  command_id="$(date +%s)-$RANDOM"
  remote_script="$TERMUX_HOME/.termux-probe-command-$command_id.sh"
  remote_result_dir="$TERMUX_HOME/.termux-probe-results-$command_id"
  remote_stdout="$remote_result_dir/stdout"
  remote_stderr="$remote_result_dir/stderr"
  remote_status="$remote_result_dir/status"

  local_script=$(mktemp "${RUNNER_TEMP:-.}/termux-command.XXXXXX")
  {
    printf '#!%s/bin/bash\n' "$TERMUX_PREFIX"
    printf 'set +e\n'
    printf '(\n'
    printf 'set -Eeuo pipefail\n'
    printf 'export HOME=%q\n' "$TERMUX_HOME"
    printf 'export PREFIX=%q\n' "$TERMUX_PREFIX"
    printf 'export TMPDIR=%q\n' "$TERMUX_PREFIX/tmp"
    printf 'export TERMUX_VERSION=ci\n'
    printf 'export PATH=%q\n' "$TERMUX_PREFIX/bin:/system/bin:/system/xbin"
    printf 'export SHELL=%q\n' "$TERMUX_PREFIX/bin/bash"
    printf 'export LANG=%q\n' 'C.UTF-8'
    printf "/system/bin/mkdir -p \"\$TMPDIR\"\n"
    # shellcheck disable=SC2016
    printf 'if [ -f "$PREFIX/lib/libtermux-exec-ld-preload.so" ]; then\n'
    # shellcheck disable=SC2016
    printf '  export LD_PRELOAD="$PREFIX/lib/libtermux-exec-ld-preload.so"\n'
    printf 'else\n'
    printf '  unset LD_PRELOAD\n'
    printf 'fi\n'
    printf 'unset LD_LIBRARY_PATH\n'
    printf "cd \"\$HOME\"\n"
    printf '%s\n' "$command_line"
    printf ') > %q 2> %q\n' "$remote_stdout" "$remote_stderr"
    printf 'status=$?\n'
    # shellcheck disable=SC2016
    printf 'printf "%%s\\n" "$status" > %q\n' "$remote_status"
    # shellcheck disable=SC2016
    printf 'exit "$status"\n'
  } > "$local_script"

  if ! adb push "$local_script" "$remote_tmp" >/dev/null; then
    rm -f "$local_script"
    return 1
  fi

  if ! run_as_termux_shell "/system/bin/mkdir -p $remote_result_dir && cp $remote_tmp $remote_script && chmod 700 $remote_script"; then
    rm -f "$local_script"
    return 1
  fi

  rm -f "$local_script"

  # Temporarily whitelist Termux to allow background FGS start
  adb shell cmd deviceidle tempwhitelist -d 30000 com.termux >/dev/null 2>&1 || true
  
  # Trigger FGS using run-as to satisfy RUN_COMMAND permission check
  if ! run_as_termux_shell "/system/bin/am start-foreground-service --user 0 -n com.termux/.app.RunCommandService -a com.termux.RUN_COMMAND --es com.termux.RUN_COMMAND_PATH $TERMUX_PREFIX/bin/bash --esa com.termux.RUN_COMMAND_ARGUMENTS $remote_script --es com.termux.RUN_COMMAND_WORKDIR $TERMUX_HOME --es com.termux.RUN_COMMAND_RUNNER app-shell" >/dev/null; then
    return 1
  fi

  for ((attempt = 1; attempt <= 600; attempt++)); do
    if run_as_termux_shell "test -f $remote_status" >/dev/null 2>&1; then
      break
    fi

    if ((attempt % 30 == 0)); then
      log "Waiting for Termux command $command_id to finish: attempt $attempt/600"
      log "--- stdout tail ---"
      run_as_termux_shell "/system/bin/tail -n 20 $remote_stdout 2>/dev/null || true" || true
      log "--- stderr tail ---"
      run_as_termux_shell "/system/bin/tail -n 20 $remote_stderr 2>/dev/null || true" || true
      log "-------------------"
    fi

    sleep 1
  done

  if ! run_as_termux_shell "test -f $remote_status" >/dev/null 2>&1; then
    run_as_termux_shell "/system/bin/cat $remote_stdout 2>/dev/null || true" || true
    run_as_termux_shell "/system/bin/cat $remote_stderr 2>/dev/null || true" >&2 || true
    echo "Timed out waiting for Termux command $command_id to finish." >&2
    return 1
  fi

  run_as_termux_shell "/system/bin/cat $remote_stdout 2>/dev/null || true" || true
  run_as_termux_shell "/system/bin/cat $remote_stderr 2>/dev/null || true" >&2 || true
  status=$(run_as_termux_shell "/system/bin/cat $remote_status" | tr -d '\r')
  if [[ "$status" == "0" ]]; then
    run_as_termux_shell "/system/bin/rm -rf $remote_script $remote_result_dir" >/dev/null 2>&1 || true
  else
    run_as_termux_shell "/system/bin/rm -f $remote_script" >/dev/null 2>&1 || true
    log "Preserved failed Termux command results: $remote_result_dir"
  fi

  [[ "$status" == "0" ]]
}

enable_termux_run_command_service() {
  log "Enabling Termux RUN_COMMAND service for probe execution."
  run_as_termux_shell "/system/bin/mkdir -p $TERMUX_HOME/.termux && echo allow-external-apps = true > $TERMUX_HOME/.termux/termux.properties"
  adb shell am force-stop com.termux
}

wait_for_termux_runtime() {
  log "Checking Termux runtime paths."
  # shellcheck disable=SC2016
  termux_exec '
test -d "$HOME"
test -x "$PREFIX/bin/bash"
test -x "$PREFIX/bin/pkg"
test -x "$PREFIX/bin/dpkg"
'
  record TERMUX_RUNTIME_READY true
}

configure_termux_repositories() {
  log "Configuring Termux package repositories."
  # shellcheck disable=SC2016
  termux_exec '
/system/bin/mkdir -p "$PREFIX/etc/apt" "$PREFIX/etc/apt/sources.list.d" "$PREFIX/etc/termux"
{
  printf "%s\n" "# This file is sourced by pkg"
  printf "%s\n" "# Termux origin repository"
  printf "%s\n" "WEIGHT=1"
  printf "%s\n" "MAIN=\"https://packages.termux.dev/apt/termux-main\""
  printf "%s\n" "ROOT=\"https://packages.termux.dev/apt/termux-root\""
  printf "%s\n" "X11=\"https://packages.termux.dev/apt/termux-x11\""
} > "$PREFIX/etc/termux/chosen_mirrors"
printf "%s\n" "deb https://packages.termux.dev/apt/termux-main stable main" > "$PREFIX/etc/apt/sources.list"
'
  record TERMUX_REPOSITORIES_CONFIGURED true
}

dump_termux_state() {
  local label=$1

  log "Diagnostics: $label"
  adb shell pidof com.termux 2>/dev/null | sed 's/^/[termux-probe] com.termux pid: /' || true
  adb shell dumpsys package com.termux 2>/dev/null \
    | grep -E 'versionName|versionCode|primaryCpuAbi|secondaryCpuAbi|dataDir' \
    | sed 's/^/[termux-probe] package: /' || true
  run_as_termux_shell '/system/bin/id' \
    | sed 's/^/[termux-probe] run-as: /' || true
}

install_termux_packages() {
  log "Installing Termux packages: ca-certificates glibc-repo glibc-runner"
  # shellcheck disable=SC2016
  termux_exec '
echo "[termux-probe] Package setup PATH=$PATH"
echo "[termux-probe] Package setup LD_PRELOAD=${LD_PRELOAD:-}"
echo "[termux-probe] Package setup termux-exec files:"
/system/bin/ls -la "$PREFIX/lib"/libtermux-exec* 2>/dev/null || true
echo "[termux-probe] Package setup dpkg=$PREFIX/bin/dpkg"
echo "[termux-probe] Package setup pkg=$PREFIX/bin/pkg"
echo "[termux-probe] Package setup command lookup:"
command -v id grep realpath pkg dpkg || true
echo "[termux-probe] Package setup preload smoke matrix:"
for termux_exec_preload in \
  "$PREFIX/lib/libtermux-exec-ld-preload.so" \
  "$PREFIX/lib/libtermux-exec-direct-ld-preload.so" \
  "$PREFIX/lib/libtermux-exec-linker-ld-preload.so" \
  none
do
  if [ "$termux_exec_preload" = none ]; then
    unset LD_PRELOAD
    echo "[termux-probe] preload=none"
  else
    export LD_PRELOAD="$termux_exec_preload"
    echo "[termux-probe] preload=$LD_PRELOAD"
  fi

  set +e
  id
  echo "[termux-probe] bare id status=$?"
  "$PREFIX/bin/id"
  echo "[termux-probe] absolute id status=$?"
  realpath "$PREFIX/bin/id"
  echo "[termux-probe] realpath status=$?"
  set -e
done
if [ -f "$PREFIX/lib/libtermux-exec-ld-preload.so" ]; then
  export LD_PRELOAD="$PREFIX/lib/libtermux-exec-ld-preload.so"
else
  unset LD_PRELOAD
fi
echo "[termux-probe] Package setup helper smoke:"
id
grep --version 2>&1 | head -n 1
realpath "$PREFIX/bin/id"
"$PREFIX/bin/dpkg" --print-architecture > "$TMPDIR/dpkg-architecture.txt"
IFS= read -r dpkg_arch < "$TMPDIR/dpkg-architecture.txt"
echo "$dpkg_arch"
test "$dpkg_arch" = "aarch64"
echo "[termux-probe] Updating Termux package metadata"
TERMUX_PKG_NO_MIRROR_SELECT=1 "$PREFIX/bin/pkg" update -y
echo "[termux-probe] Installing ca-certificates and glibc-repo"
TERMUX_PKG_NO_MIRROR_SELECT=1 "$PREFIX/bin/pkg" install -y ca-certificates glibc-repo
echo "[termux-probe] Updating Termux glibc package metadata"
TERMUX_PKG_NO_MIRROR_SELECT=1 "$PREFIX/bin/pkg" update -y
echo "[termux-probe] Installing glibc-runner"
TERMUX_PKG_NO_MIRROR_SELECT=1 "$PREFIX/bin/pkg" install -y glibc-runner
test -e "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
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
echo "[termux-probe] Extracted PR artifact bin directory:"
ls -la bin
echo "[termux-probe] Available glibc loader paths:"
ls -la "$PREFIX/glibc/lib" 2>/dev/null || true
if command -v file >/dev/null 2>&1; then
  file bin/agy bin/agy.va39 || true
fi
if command -v readelf >/dev/null 2>&1; then
  readelf -l bin/agy.va39 2>/dev/null | sed -n "/interpreter/p" || true
fi
echo "[termux-probe] Running PR artifact: ./bin/agy --help"
./bin/agy --help
'
  record TERMUX_PR_ARTIFACT_SMOKE "passed"
}

test_release_standalone_archive() {
  local release_tag=${TERMUX_RELEASE_TEST_TAG:-}
  local quoted_release_tag

  if [[ -z "$release_tag" ]]; then
    return 0
  fi

  log "Testing standalone release artifact: $release_tag"
  printf -v quoted_release_tag '%q' "$release_tag"

  termux_exec "
RELEASE_TAG=$quoted_release_tag
rm -rf \"\$HOME/agy-release-smoke\"
mkdir -p \"\$HOME/agy-release-smoke\"
cd \"\$HOME/agy-release-smoke\"
curl -fsSLO \"https://github.com/wallentx/antigravity-cli-termux/releases/download/\${RELEASE_TAG}/antigravity-termux-standalone.tar.gz\"
tar -xzf antigravity-termux-standalone.tar.gz
echo \"[termux-probe] Extracted release artifact bin directory:\"
ls -la bin
echo \"[termux-probe] Available glibc loader paths:\"
ls -la \"\$PREFIX/glibc/lib\" 2>/dev/null || true
if command -v file >/dev/null 2>&1; then
  file bin/agy bin/agy.va39 || true
fi
if command -v readelf >/dev/null 2>&1; then
  readelf -l bin/agy.va39 2>/dev/null | sed -n \"/interpreter/p\" || true
fi
echo \"[termux-probe] Running release artifact: ./bin/agy --help\"
./bin/agy --help
"
  record TERMUX_RELEASE_ARTIFACT_SMOKE "$release_tag"
}

wait_for_termux_bootstrap() {
  local attempt

  log "Waiting for Termux bootstrap: $bootstrap_attempts attempts, ${bootstrap_interval_seconds}s interval"
  for ((attempt = 1; attempt <= bootstrap_attempts; attempt++)); do
    if run_as_termux_shell "test -x $TERMUX_PREFIX/bin/bash" >/dev/null 2>&1; then
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

use_restored_termux_bootstrap() {
  [[ "${TERMUX_RESTORE_SNAPSHOT:-false}" == "true" ]]
}

log "Starting Termux emulator probe."
device_abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
device_abilist=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')
native_bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')
record ANDROID_CPU_ABI "$device_abi"
record ANDROID_CPU_ABILIST "$device_abilist"
record ANDROID_NATIVE_BRIDGE "${native_bridge:-none}"
record TERMUX_CHANNEL "${TERMUX_CHANNEL:-unknown}"
record TERMUX_RELEASE_TAG "${TERMUX_RELEASE_TAG:-unknown}"
record TERMUX_APK_NAME "${TERMUX_APK_NAME:-unknown}"
record TERMUX_APK_URL "${TERMUX_APK_URL:-none}"
record TERMUX_INSTALL_ABI "$termux_install_abi"
record TERMUX_BOOTSTRAP_ATTEMPTS "$bootstrap_attempts"
record TERMUX_BOOTSTRAP_INTERVAL_SECONDS "$bootstrap_interval_seconds"
record TERMUX_RESTORE_SNAPSHOT "${TERMUX_RESTORE_SNAPSHOT:-false}"
record TERMUX_RESTORED_AVD_CACHE "${TERMUX_RESTORED_AVD_CACHE:-false}"
record TERMUX_RESTORED_AVD_CACHE_KEY "${TERMUX_RESTORED_AVD_CACHE_KEY:-none}"
record TERMUX_SAVE_SNAPSHOT "${TERMUX_SAVE_SNAPSHOT:-false}"
record TERMUX_AVD_CACHE_PREFIX "${TERMUX_AVD_CACHE_PREFIX:-unknown}"
record TERMUX_AVD_CACHE_KEY "${TERMUX_AVD_CACHE_KEY:-unknown}"
record TERMUX_STANDALONE_ARCHIVE "${TERMUX_STANDALONE_ARCHIVE:-none}"
record TERMUX_PR_SOURCE_RUN_ID "${TERMUX_PR_SOURCE_RUN_ID:-none}"
record TERMUX_RELEASE_TEST_TAG "${TERMUX_RELEASE_TEST_TAG:-none}"
record TERMUX_EXTRA_COMMANDS_PRESENT "$([[ -n "${TERMUX_EXTRA_COMMANDS:-}" ]] && echo true || echo false)"
record TERMUX_EXTRA_COMMANDS_AT_START "${TERMUX_EXTRA_COMMANDS_AT_START:-false}"

if use_restored_termux_bootstrap; then
  log "Using restored Termux bootstrap; skipping APK install and first-launch bootstrap."
  record TERMUX_BOOTSTRAP_SOURCE "restored-snapshot"
else
  log "Installing Termux APK: ${TERMUX_APK_NAME:-unknown}"
  adb install -r --abi "$termux_install_abi" termux.apk
  adb shell pm grant com.termux android.permission.POST_NOTIFICATIONS || true
  dump_termux_state "after apk install"
  log "Launching Termux."
  adb shell monkey -p com.termux -c android.intent.category.LAUNCHER 1 >/dev/null

  if ! wait_for_termux_bootstrap; then
    dump_termux_state "bootstrap timeout"
    echo "Termux did not finish bootstrap within the timeout." >&2
    exit 1
  fi
  record TERMUX_BOOTSTRAP_SOURCE "fresh-apk"
fi

enable_termux_run_command_service

wait_for_termux_runtime

log "Validating Termux command environment."
termux_exec_pwd=$(termux_exec 'pwd' | tr -d '\r')
termux_exec_id=$(termux_exec '/system/bin/id' | tr -d '\r')
termux_exec_path=$(termux_exec "printf '%s\n' \"\$PATH\"" | tr -d '\r')
# shellcheck disable=SC2016
termux_exec_ld_library_path=$(termux_exec 'printf "%s\n" "${LD_LIBRARY_PATH:-}"' | tr -d '\r')
# shellcheck disable=SC2016
termux_pkg_path=$(termux_exec 'printf "%s\n" "$PREFIX/bin/pkg"' | tr -d '\r')

record TERMUX_EXEC_PWD "$termux_exec_pwd"
record TERMUX_EXEC_ID "$termux_exec_id"
record TERMUX_EXEC_PATH "$termux_exec_path"
record TERMUX_EXEC_LD_LIBRARY_PATH "$termux_exec_ld_library_path"
record TERMUX_PKG_PATH "$termux_pkg_path"

if [[ "${TERMUX_RESTORE_SNAPSHOT:-false}" != "true" ]]; then
  configure_termux_repositories
fi

if [[ "${TERMUX_EXTRA_COMMANDS_AT_START:-false}" == "true" ]]; then
  run_extra_termux_commands start
fi

if [[ "${TERMUX_RESTORE_SNAPSHOT:-false}" == "true" ]]; then
  record TERMUX_PACKAGE_SETUP "skipped-restored-snapshot"
else
  install_termux_packages
fi

log "Collecting Termux runtime details."
termux_arch=$(termux_exec '/system/bin/uname -m' | tr -d '\r')
# shellcheck disable=SC2016
termux_dpkg_arch=$(termux_exec '"$PREFIX/bin/dpkg" --print-architecture 2>/dev/null || true' | tr -d '\r')
termux_loader_state=$(termux_exec "test -e \"\$PREFIX/glibc/lib/ld-linux-aarch64.so.1\" && echo present || echo missing" | tr -d '\r')
termux_x86_loader_state=$(termux_exec "test -e \"\$PREFIX/glibc/lib/ld-linux-x86-64.so.2\" && echo present || echo missing" | tr -d '\r')

record TERMUX_UNAME_M "$termux_arch"
record TERMUX_DPKG_ARCH "$termux_dpkg_arch"
record TERMUX_AARCH64_GLIBC_LOADER "$termux_loader_state"
record TERMUX_X86_64_GLIBC_LOADER "$termux_x86_loader_state"

test_host_standalone_archive
test_release_standalone_archive

if [[ "${TERMUX_EXTRA_COMMANDS_AT_START:-false}" != "true" ]]; then
  run_extra_termux_commands end
fi

{
  echo "### Termux Emulator Probe"
  echo ""
  echo "| Field | Value |"
  echo "| --- | --- |"
  # shellcheck disable=SC2016
  sed 's/|/\\|/g; s/^\([^=]*\)=\(.*\)$/| `\1` | `\2` |/' "$probe_file"
  echo ""
} >> "$GITHUB_STEP_SUMMARY"
