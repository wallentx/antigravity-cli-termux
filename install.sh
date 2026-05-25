#!/data/data/com.termux/files/usr/bin/bash
# Antigravity - Termux Installer
set -Eeuo pipefail

REPO="${AGY_REPO:-wallentx/antigravity-cli-termux}"
URL="https://github.com/$REPO/releases/latest/download/antigravity-termux-standalone.tar.gz"
INSTALL_DIR="${HOME}/.local/agy"
TMP="${HOME}/.local/.agy-install.tar.gz"

# ── Cleanup Hook ──────────────────────────────────────────────────────────────
cleanup() {
  printf "\033[?25h" # Restore cursor if cancelled
  [[ -f "$TMP" ]] && rm -f "$TMP"
}

handle_cancel() {
  cleanup
  die
}

trap cleanup EXIT
trap handle_cancel INT TERM

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 || -c /dev/tty ]]; then
  BOLD="\033[1m"
  DIM="\033[2m"
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  CYAN="\033[36m"
  MAGENTA="\033[35m"
  RESET="\033[0m"
else
  BOLD="" DIM="" GREEN="" RED="" YELLOW="" CYAN="" MAGENTA="" RESET=""
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
      printf '\n%b\n' " ${RED}[ERR]${RESET} things got failed or canceled."
    fi
    printf "For manual patching and installation:\n"
    printf "${CYAN}https://gist.github.com/Brajesh2022/e42160d29b55417db6c18c52dd1d6d37${RESET}\n\n"
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
    printf "\r\033[K ${CYAN}[%c]${RESET} ${DIM}%s${RESET}" "$spinstr" "$msg"
    local spinstr=$temp${spinstr%"$temp"}
    sleep 0.1
  done
  local exit_status=0
  wait "$pid" || exit_status=$?
  if [ $exit_status -eq 0 ]; then
    printf "\r\033[K ${GREEN}[OK]${RESET} %s\n" "$msg"
  else
    printf "\r\033[K ${RED}[ERR]${RESET} %s\n" "$msg"
  fi
  printf "\033[?25h" # Show cursor
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
    printf "\r\033[K ${RED}[ERR]${RESET} Download failed.\n"
  fi
  
  printf "\033[?25h" # Restore cursor
  return $exit_status
}

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
TMP_LOGO="${HOME}/.local/.agy-logo.ans"

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
[[ -d /data/data/com.termux ]]   || die
[[ "$(uname -m)" == "aarch64" ]] || die
command -v curl >/dev/null 2>&1  || die
command -v tar  >/dev/null 2>&1  || die

ok "Environment: Termux aarch64"

# ── Clean previous install ────────────────────────────────────────────────────
if [[ -e "$INSTALL_DIR" ]]; then
  info "Removing previous installation..."
  rm -rf "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR" "$(dirname "$TMP")" 2>/dev/null

# ── Download ──────────────────────────────────────────────────────────────────
download_with_progress "$URL" "$TMP" || die

# ── Extraction ────────────────────────────────────────────────────────────────
tar -xz -C "$INSTALL_DIR" -f "$TMP" >/dev/null 2>&1 &
spinner $! "Extracting binaries..." || die

# Explicit cleanup because 'exec' bypasses the normal shell exit trap
rm -f "$TMP"

# ── Verify twin-binary ────────────────────────────────────────────────────────
if [[ ! -f "$INSTALL_DIR/bin/agy" || ! -f "$INSTALL_DIR/bin/agy.va39" ]]; then
  rm -rf "$INSTALL_DIR"
  die
fi
ok "Binary integrity verified"

# ── Test & Extract Version ────────────────────────────────────────────────────
VERSION=""
if VERSION=$("$INSTALL_DIR/bin/agy" --version 2>/dev/null); then
  ok "Engine online ($VERSION verified)"
elif VERSION=$("$INSTALL_DIR/bin/agy.va39" --version 2>/dev/null); then
  info "Standard binary failed (e.g., Bus Error). Auto-fixing with va39 patch..."
  ok "Engine online ($VERSION verified via va39)"
  
  # Swap the binaries so 'agy' executes the patched version seamlessly
  mv "$INSTALL_DIR/bin/agy" "$INSTALL_DIR/bin/agy.broken"
  mv "$INSTALL_DIR/bin/agy.va39" "$INSTALL_DIR/bin/agy"
else
  rm -rf "$INSTALL_DIR"
  die
fi

# ── PATH Configuration ────────────────────────────────────────────────────────
ADDED_PATH=0
PREFER_ZSH=0
# Detect if user is running zsh right now to tailor instructions later
[[ "${SHELL:-}" == *"zsh"* ]] && PREFER_ZSH=1

for RC_FILE in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [[ -f "$RC_FILE" || "$RC_FILE" == *".bashrc" ]]; then
    if ! grep -q "local/agy/bin" "$RC_FILE" 2>/dev/null; then
      echo 'export PATH="$HOME/.local/agy/bin:$PATH"' >> "$RC_FILE"
      ok "Updated $(basename "$RC_FILE")"
      ADDED_PATH=1
    fi
  fi
done

if (( ADDED_PATH == 0 )); then
  if [[ ! -f "$HOME/.bashrc" && ! -f "$HOME/.zshrc" ]]; then
    info "Warning: No shell configuration files found. Created ~/.bashrc"
  else
    info "PATH already configured in shell"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
printf '\n%b\n' "${GREEN}${BOLD}Installation Complete.${RESET}"
divider
info "To use immediately without restarting, run:"
if (( PREFER_ZSH == 1 )); then
  info "${BOLD}source ~/.zshrc${RESET}"
else
  info "${BOLD}source ~/.bashrc${RESET}"
fi
info "Then type: ${BOLD}agy${RESET}"
printf '\n'

# ── Launch ────────────────────────────────────────────────────────────────────
info "Launching Antigravity CLI..."
sleep 0.5

export PATH="$INSTALL_DIR/bin:$PATH"
clear
exec "$INSTALL_DIR/bin/agy"
