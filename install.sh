#!/usr/bin/env bash
# Antigravity - Termux Installer
set -Eeuo pipefail

REPO="${AGY_REPO:-wallentx/antigravity-cli-termux}"
URL="https://github.com/$REPO/releases/latest/download/antigravity-termux-standalone.tar.gz"

# ── Environment Detection ─────────────────────────────────────────────────────
tp=$(awk '/^TracerPid:/ {print $2}' /proc/self/status 2>/dev/null || echo 0)
tn=""
if [[ "$tp" -gt 0 ]]; then
  tn=$(awk '/^Name:/ {print $2}' "/proc/$tp/status" 2>/dev/null || cat "/proc/$tp/comm" 2>/dev/null || true)
fi

ENV_TYPE="unknown"
case "$tn" in
  proot|proot-*|proot_*) ENV_TYPE="proot" ;;
  *)
    if [[ -n "${TERMUX_VERSION:-}" ]]; then
      ENV_TYPE="termux"
    fi
    ;;
esac

if [[ "$ENV_TYPE" == "unknown" ]]; then
  printf "\033[31m[ERR]\033[0m This install script is exclusively designed for native Termux or Termux PRoot distro environments.\n" >&2
  exit 1
fi

if [[ "$ENV_TYPE" == "termux" ]]; then
  TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
  INSTALL_BIN_DIR="${TERMUX_PREFIX}/bin"
  TMP="${TERMUX_PREFIX}/tmp/antigravity-termux-standalone.tar.gz"
  EXTRACT_DIR="${TERMUX_PREFIX}/tmp/.agy-extract"
else
  INSTALL_BIN_DIR="$HOME/.local/bin"
  TMP="${TMPDIR:-/tmp}/antigravity-termux-standalone.tar.gz"
  EXTRACT_DIR="${TMPDIR:-/tmp}/.agy-extract"
fi
INSTALL_SUCCESS=0

# Ensure base directories exist for fresh setups
mkdir -p "$(dirname "$TMP")" 2>/dev/null || true

# ── Cleanup Hook ──────────────────────────────────────────────────────────────
cleanup() {
  printf "\033[?25h" # Restore cursor if cancelled
  [[ -n "${TMP_LOGO:-}" && -f "$TMP_LOGO" ]] && rm -f "$TMP_LOGO"
  [[ -n "${GLIBC_LOG:-}" && -f "$GLIBC_LOG" ]] && rm -f "$GLIBC_LOG"
  [[ -n "${GLIBC_PCT:-}" && -f "$GLIBC_PCT" ]] && rm -f "$GLIBC_PCT"
  [[ -d "$EXTRACT_DIR" ]] && rm -rf "$EXTRACT_DIR"
  if [[ "${INSTALL_SUCCESS:-0}" -ne 1 ]]; then
    [[ -f "$TMP" ]] && rm -f "$TMP"
    [[ -n "${AGY_BAK:-}" && -f "$AGY_BAK" ]] && mv -f "$AGY_BAK" "$INSTALL_BIN_DIR/agy" || true
    [[ -n "${AGY_VA39_BAK:-}" && -f "$AGY_VA39_BAK" ]] && mv -f "$AGY_VA39_BAK" "$INSTALL_BIN_DIR/agy.va39" || true
  else
    [[ -n "${AGY_BAK:-}" && -f "$AGY_BAK" ]] && rm -f "$AGY_BAK" || true
    [[ -n "${AGY_VA39_BAK:-}" && -f "$AGY_VA39_BAK" ]] && rm -f "$AGY_VA39_BAK" || true
  fi
}

handle_cancel() {
  cleanup
  die
}

trap cleanup EXIT
trap handle_cancel INT TERM

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD="\033[1m"
  DIM="\033[2m"
  GREEN="\033[32m"
  RED="\033[31m"
  CYAN="\033[36m"
  RESET="\033[0m"
else
  BOLD="" DIM="" GREEN="" RED="" CYAN="" RESET=""
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf '%b\n' " ${CYAN}[..]${RESET} ${DIM}$*${RESET}"; }
ok()      { printf '%b\n' " ${GREEN}[OK]${RESET} $*"; }
die() {
  {
    printf "\033[?25h" # Restore cursor
    if [[ $# -gt 0 ]]; then
      printf '\n%b\n' " ${RED}[ERR]${RESET} $*"
    else
      printf '\n%b\n' " ${RED}[ERR]${RESET} Installation failed or was cancelled."
    fi
    printf "For manual patching and installation:\n"
    printf "%bhttps://gist.github.com/Brajesh2022/e42160d29b55417db6c18c52dd1d6d37%b\n\n" "$CYAN" "$RESET"
  } >&2
  exit 1
}
divider() { printf '%b\n' "${DIM}────────────────────────────────────────${RESET}"; }

spinner() {
  local pid=$1
  local msg=$2
  local spinstr='\|/-'
  printf "\033[?25l" # Hide cursor
  while kill -0 "$pid" 2>/dev/null; do
    local temp=${spinstr#?}
    printf "\r\033[K %b[%c]%b %b%s%b" "$CYAN" "$spinstr" "$RESET" "$DIM" "$msg" "$RESET"
    local spinstr=$temp${spinstr%"$temp"}
    sleep 0.1
  done
  local exit_status=0
  wait "$pid" || exit_status=$?
  if [ $exit_status -eq 0 ]; then
    printf "\r\033[K %b[OK]%b %s\n" "$GREEN" "$RESET" "$msg"
  else
    printf "\r\033[K %b[ERR]%b %s\n" "$RED" "$RESET" "$msg"
  fi
  printf "\033[?25h" # Show cursor
  return $exit_status
}

progress_spinner() {
  local pid=$1
  local msg=$2
  local pct_file=$3
  local spinstr='\|/-'
  printf "\033[?25l" # Hide cursor
  while kill -0 "$pid" 2>/dev/null; do
    local temp=${spinstr#?}
    local pct="  0"
    if [[ -f "$pct_file" ]]; then
      pct=$(tail -n 1 "$pct_file" 2>/dev/null || echo "  0")
    fi
    printf "\r\033[K %b[%c]%b [%3s%%] %b%s%b" "$CYAN" "$spinstr" "$RESET" "$pct" "$DIM" "$msg" "$RESET"
    local spinstr=$temp${spinstr%"$temp"}
    sleep 0.1
  done
  local exit_status=0
  wait "$pid" || exit_status=$?
  if [ $exit_status -eq 0 ]; then
    printf "\r\033[K %b[OK]%b %s\n" "$GREEN" "$RESET" "$msg"
  else
    printf "\r\033[K %b[ERR]%b %s\n" "$RED" "$RESET" "$msg"
  fi
  printf "\033[?25h" # Restore cursor
  return $exit_status
}

download_with_progress() {
  local url=$1
  local dest=$2

  printf "\033[?25l" # Hide cursor

  local total_size=""
  if head_out=$(curl -sLI -H "Cache-Control: no-cache" "$url" 2>/dev/null); then
    total_size=$(echo "$head_out" | awk 'BEGIN{IGNORECASE=1} /^content-length:/{print $2}' | tail -n1 | tr -d '\r')
  fi

  if [[ ! "$total_size" =~ ^[0-9]+$ ]]; then
    curl -fLs -H "Cache-Control: no-cache" "$url" -o "$dest" >/dev/null 2>&1 &
    spinner $! "Downloading payload..."
    return $?
  fi

  local cols
  cols=$(tput cols </dev/tty 2>/dev/null || echo 60)

  local w=$(( cols - 38 ))
  (( w > 60 )) && w=60
  (( w < 10 )) && w=10

  curl -fLs -H "Cache-Control: no-cache" "$url" -o "$dest" >/dev/null 2>&1 &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    local current_size=0
    if [[ -f "$dest" ]]; then
      current_size=$(wc -c < "$dest" 2>/dev/null || echo 0)
    fi

    awk -v c="$current_size" -v t="$total_size" -v cyan="$CYAN" -v dim="$DIM" -v rst="$RESET" -v width="$w" '
    BEGIN {
      pct = (t > 0) ? (c / t) * 100 : 0
      if (pct > 100) pct = 100
      filled = int((pct / 100) * width)
      empty = width - filled

      bar = ""
      for (i=0; i<filled; i++) bar = bar "█"
      for (i=0; i<empty; i++) bar = bar "░"

      c_mb = c / 1048576
      t_mb = t / 1048576

      printf "\r\033[K %s[..]%s [%s] %3d%% %s%5.1fM / %4.1fM%s", cyan, rst, bar, pct, dim, c_mb, t_mb, rst
    }'
    sleep 0.15
  done

  local exit_status=0
  wait "$pid" || exit_status=$?

  if [ $exit_status -eq 0 ]; then
    awk -v t="$total_size" -v grn="$GREEN" -v dim="$DIM" -v rst="$RESET" -v width="$w" '
    BEGIN {
      bar = ""
      for (i=0; i<width; i++) bar = bar "█"
      t_mb = t / 1048576
      printf "\r\033[K %s[OK]%s [%s] 100%% %s%5.1fM / %4.1fM%s\n", grn, rst, bar, dim, t_mb, t_mb, rst
    }'
  else
    printf "\r\033[K %b[ERR]%b Download failed.\n" "$RED" "$RESET"
  fi

  printf "\033[?25h" # Restore cursor
  return $exit_status
}

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
TMP_LOGO=$(mktemp 2>/dev/null || echo "${HOME}/.local/.agy-logo.ans")

if { curl -fLs -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/${REPO}/dev/logo.ans" > "$TMP_LOGO" 2>/dev/null || curl -fLs -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/Brajesh2022/antigravity-cli-termux/dev/logo.ans" > "$TMP_LOGO" 2>/dev/null; } && [[ -s "$TMP_LOGO" ]]; then

  COLS=$(tput cols </dev/tty 2>/dev/null || echo 60)

  awk -v cols="$COLS" -v arch="$(uname -m)" -v bold="${BOLD}${CYAN}" -v dim="${DIM}" -v grn="${GREEN}" -v rst="${RESET}" '
  {
    sub(/\r$/, "");

    if (cols >= 48) {
      printf "%s", $0;
      if (NR == 3)      printf "\033[28G %sAntigravity Termux%s", bold, rst;
      else if (NR == 4) printf "\033[28G %sStandalone Installer%s", dim, rst;
      else if (NR == 5) printf "\033[28G %s────────────────────%s", dim, rst;
      else if (NR == 6) printf "\033[28G %sTarget:%s  Termux", dim, rst;
      else if (NR == 7) printf "\033[28G %sArch:%s    %s", dim, rst, arch;
      else if (NR == 8) printf "\033[28G %sStatus:%s  %sOnline%s", dim, rst, grn, rst;
      printf "\n";
    } else {
      print $0;
    }
  }
  END {
    if (cols < 48) {
      printf "\n";
      printf "  %sAntigravity Termux%s\n", bold, rst;
      printf "  %sStandalone Installer%s\n", dim, rst;
      printf "  %s────────────────────%s\n", dim, rst;
      printf "  %sTarget:%s  Termux\n", dim, rst;
      printf "  %sArch:%s    %s\n", dim, rst, arch;
      printf "  %sStatus:%s  %sOnline%s\n", dim, rst, grn, rst;
    }
  }' "$TMP_LOGO"

  rm -f "$TMP_LOGO"
else
  printf "  %bAntigravity Termux%b\n" "${BOLD}${CYAN}" "${RESET}"
  printf "  %bStandalone Installer%b\n" "${DIM}" "${RESET}"
fi
echo ""
divider

# ── Environment check ─────────────────────────────────────────────────────────
[[ "$(uname -m)" == "aarch64" ]] || die "Architecture must be aarch64"
command -v curl >/dev/null 2>&1  || die "curl is required"
command -v tar  >/dev/null 2>&1  || die "tar is required"

check_glibc() {
  if [[ "$ENV_TYPE" == "termux" ]]; then
    [[ -d "${TERMUX_PREFIX}/glibc" ]]
  else
    ldd --version 2>&1 | grep -qi -E '(glibc|gnu libc)'
  fi
}

if ! check_glibc; then
  if [[ "$ENV_TYPE" == "termux" ]]; then
    command -v pkg >/dev/null 2>&1 || die "pkg is required to install glibc"

    printf "\n  %b[!]%b The glibc package is required but not installed.\n" "$RED" "$RESET"
    printf "  Would you like to install it now via pkg? [Y/n]: "
    read -r -n 1 ans < /dev/tty || ans="n"
    printf "\n"

    if [[ "$ans" =~ ^[Yy]$ ]] || [[ -z "$ans" ]]; then
      GLIBC_LOG="${TMP}.glibc.log"
      GLIBC_PCT="${TMP}.pct"
      echo "0" > "$GLIBC_PCT"
      {
        {
          pkg install -y glibc-repo -o APT::Status-Fd=1 || true
          pkg install -y glibc -o APT::Status-Fd=1
        } 2>&1 | tee -a "$GLIBC_LOG" | awk '
          /^dlstatus:[0-9]+:([0-9.]+):/ || /^pmstatus:[^:]+:([0-9.]+):/ {
            split($0, a, ":")
            pct = int(a[3])
            if (pct < 0) pct = 0
            if (pct > 100) pct = 100
            print pct > "'"${GLIBC_PCT}"'"
            close("'"${GLIBC_PCT}"'")
            fflush()
          }'
      } &
      progress_spinner $! "Setting up Termux glibc environment..." "$GLIBC_PCT" || true
      rm -f "$GLIBC_PCT"

      if ! check_glibc; then
        [[ -f "$GLIBC_LOG" ]] && tail -n 30 "$GLIBC_LOG" >&2
        die "Failed to install Termux glibc. Please install manually: pkg update && pkg install -y glibc-repo glibc"
      fi
      rm -f "$GLIBC_LOG"
    else
      die "glibc is required to proceed. Please install it manually."
    fi
  else
    die "glibc is required but not found. Please install glibc using your distribution's package manager."
  fi
fi

ok "Environment: ${ENV_TYPE} (aarch64)"

# ── Clean previous install ────────────────────────────────────────────────────
mkdir -p "$INSTALL_BIN_DIR" "$(dirname "$TMP")" 2>/dev/null
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

# ── Download ──────────────────────────────────────────────────────────────────
download_with_progress "$URL" "$TMP" || die

# ── Extraction ────────────────────────────────────────────────────────────────
tar -xz -C "$EXTRACT_DIR" -f "$TMP" bin/agy bin/agy.va39 >/dev/null 2>&1 &
spinner $! "Extracting binaries..." || die

AGY_BAK=""
AGY_VA39_BAK=""
if [[ -f "$INSTALL_BIN_DIR/agy" ]]; then
  AGY_BAK="$INSTALL_BIN_DIR/agy.bak.$$"
  mv -f "$INSTALL_BIN_DIR/agy" "$AGY_BAK" || die "Failed to back up existing agy binary from $INSTALL_BIN_DIR"
fi
if [[ -f "$INSTALL_BIN_DIR/agy.va39" ]]; then
  AGY_VA39_BAK="$INSTALL_BIN_DIR/agy.va39.bak.$$"
  mv -f "$INSTALL_BIN_DIR/agy.va39" "$AGY_VA39_BAK" || die "Failed to back up existing agy.va39 binary from $INSTALL_BIN_DIR"
fi

install -m 0755 "$EXTRACT_DIR/bin/agy" "$INSTALL_BIN_DIR/agy" || die "Failed to install agy binary to $INSTALL_BIN_DIR"
install -m 0755 "$EXTRACT_DIR/bin/agy.va39" "$INSTALL_BIN_DIR/agy.va39" || die "Failed to install agy.va39 binary to $INSTALL_BIN_DIR"
rm -rf "$EXTRACT_DIR"

# ── Verify twin-binary ────────────────────────────────────────────────────────
if [[ ! -f "$INSTALL_BIN_DIR/agy" || ! -f "$INSTALL_BIN_DIR/agy.va39" ]]; then
  rm -f "$INSTALL_BIN_DIR/agy" "$INSTALL_BIN_DIR/agy.va39"
  die "Verification failed: binaries not found in $INSTALL_BIN_DIR"
fi
ok "Binary found"

# ── Test & Extract Version ────────────────────────────────────────────────────
VERSION=""
if VERSION=$("$INSTALL_BIN_DIR/agy" --version 2>/dev/null); then
  ok "Engine online ($VERSION verified)"
  [[ -n "$AGY_BAK" && -f "$AGY_BAK" ]] && rm -f "$AGY_BAK"
  [[ -n "$AGY_VA39_BAK" && -f "$AGY_VA39_BAK" ]] && rm -f "$AGY_VA39_BAK"
else
  info "Binary failed. Attempting dependency repair..."
  pkg reinstall -y proot glibc ca-certificates >/dev/null 2>&1 || true
  rm -f ~/.local/bin/agy ~/.local/bin/agy.va39
  rm -rf ~/.local/agy
  hash -r
  
  if VERSION=$("$INSTALL_BIN_DIR/agy" --version 2>/dev/null); then
    ok "Engine online ($VERSION verified)"
    [[ -n "$AGY_BAK" && -f "$AGY_BAK" ]] && rm -f "$AGY_BAK"
    [[ -n "$AGY_VA39_BAK" && -f "$AGY_VA39_BAK" ]] && rm -f "$AGY_VA39_BAK"
  else
    info "Repair failed. Attempting full package update..."
    pkg upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" >/dev/null 2>&1 || true
    pkg reinstall -y proot glibc ca-certificates >/dev/null 2>&1 || true
    
    if VERSION=$("$INSTALL_BIN_DIR/agy" --version 2>/dev/null); then
      ok "Engine online ($VERSION verified)"
      [[ -n "$AGY_BAK" && -f "$AGY_BAK" ]] && rm -f "$AGY_BAK"
      [[ -n "$AGY_VA39_BAK" && -f "$AGY_VA39_BAK" ]] && rm -f "$AGY_VA39_BAK"
    else
      rm -f "$INSTALL_BIN_DIR/agy" "$INSTALL_BIN_DIR/agy.va39"
      die "Binaries failed to execute locally. Check dependencies."
    fi
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
printf '\n%b\n' "${GREEN}${BOLD}Installation Complete.${RESET}"
divider
info "Installed binaries to: ${BOLD}${INSTALL_BIN_DIR}${RESET}"
info "Release archive kept at: ${BOLD}${TMP}${RESET}"
info "Optional verification:"
info "${BOLD}cd $(dirname "$TMP") && gh attestation verify antigravity-termux-standalone.tar.gz --owner wallentx${RESET}"
printf '\n'

case ":$PATH:" in
  *":$INSTALL_BIN_DIR:"*) ;;
  *)
    cat >&2 <<EOF
${RED}${BOLD}Warning:${RESET} ${BOLD}$INSTALL_BIN_DIR${RESET} is not in PATH for this shell.
Please add this to your shell profile (e.g., ~/.bashrc or ~/.zshrc):

  export PATH="$INSTALL_BIN_DIR:\$PATH"

EOF
    ;;
esac

# ── Launch ────────────────────────────────────────────────────────────────────
info "Launching Antigravity CLI..."

export PATH="$INSTALL_BIN_DIR:$PATH"
INSTALL_SUCCESS=1
cleanup
exec "$INSTALL_BIN_DIR/agy"
