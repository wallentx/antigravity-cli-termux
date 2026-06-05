#!/usr/bin/env bash
# Antigravity CLI Termux Standalone Binary Builder
# Fetches/compiles the C bootstrapper and applies VA39 memory patches.
set -Eeuo pipefail

# Enforce execution from the script's directory root
cd "$(dirname "$0")"

# Configuration and defaults
MANIFEST_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json"

# Color definitions
if [[ -t 1 ]]; then
  DIM="\033[2m"
  GREEN="\033[32m"
  RED="\033[31m"
  CYAN="\033[36m"
  RESET="\033[0m"
else
  DIM="" GREEN="" RED="" CYAN="" RESET=""
fi

# Logging helpers
info()    { printf '%b\n' " ${CYAN}[..]${RESET} ${DIM}$*${RESET}"; }
ok()      { printf '%b\n' " ${GREEN}[OK]${RESET} $*"; }
error()   { printf '%b\n' " ${RED}[ERR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# Help and usage
show_help() {
  cat <<EOF
Usage: $(basename "$0") [path_to_upstream_antigravity]

Compiles the native C bootstrapper and applies VA39 memory patches.

Arguments:
  [path_to_upstream_antigravity]   Optional. Path to a local raw arm64 binary.
                                   If omitted, fetches the latest upstream binary automatically.

Environment:
  AGY_VERSION                      Version to embed when building from a local binary.
                                   Required if that binary cannot run on this host.

Requirements:
  - curl, jq, tar, python3
  - clang or gcc (or \$ANDROID_NDK_HOME configured for cross-compiling)
EOF
}

# Check for help flag
if [[ "${1:-}" = "-h" || "${1:-}" = "--help" ]]; then
  show_help
  exit 0
fi

# Cleanup Hook
cleanup() {
  if [[ -d "staging" ]]; then
    info "Cleaning up staging directory..."
    rm -rf staging
  fi
}
trap cleanup EXIT

# Prerequisite checks
check_prereqs() {
  info "Checking build prerequisites..."
  local missing=()
  for cmd in curl jq tar python3; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required command-line utilities: ${missing[*]}"
  fi
}

# Compiler detection
detect_compiler() {
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    local ndk_clang
    ndk_clang=$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -name "aarch64-linux-android*-clang" -print -quit 2>/dev/null)
    if [[ -n "$ndk_clang" && -x "$ndk_clang" ]]; then
      echo "$ndk_clang"
      return 0
    fi
  fi

  if [[ -x "/data/data/com.termux/files/usr/bin/clang" ]]; then
    echo "/data/data/com.termux/files/usr/bin/clang"
    return 0
  fi

  if command -v clang &>/dev/null; then
    echo "clang"
    return 0
  elif command -v gcc &>/dev/null; then
    echo "gcc"
    return 0
  fi

  return 1
}

# Main builder logic
check_prereqs

# Detect C compiler
local_cc=""
if ! local_cc=$(detect_compiler); then
  die "No suitable C compiler found (clang/gcc or ANDROID_NDK_HOME not configured)."
fi
info "Selected C compiler: $local_cc"

# Create directories
mkdir -p staging bin

UPSTREAM_BIN=""
using_local_upstream=0

if [[ $# -gt 0 ]]; then
  using_local_upstream=1
  UPSTREAM_BIN="$1"
  if [[ ! -f "$UPSTREAM_BIN" ]]; then
    die "Specified upstream binary not found: $UPSTREAM_BIN"
  fi
  info "Using local upstream binary: $UPSTREAM_BIN"
else
  info "Querying latest official version..."
  manifest=$(curl -fsSL "$MANIFEST_URL")
  if [[ -z "$manifest" ]]; then
    die "Failed to query manifest from $MANIFEST_URL"
  fi
  
  latest_version=$(echo "$manifest" | jq -r .version)
  download_url=$(echo "$manifest" | jq -r .url)
  
  info "Latest official version found: v$latest_version"
  info "Downloading upstream dynamic binary..."
  if ! curl -fsSL -o staging/agy.tar.gz "$download_url"; then
    die "Failed to download upstream binary from $download_url"
  fi
  
  info "Extracting upstream dynamic binary..."
  if ! tar -xzf staging/agy.tar.gz -C staging/; then
    die "Failed to extract upstream binary."
  fi
  
  if [[ -f "staging/antigravity" ]]; then
    UPSTREAM_BIN="staging/antigravity"
  elif [[ -f "staging/agy" ]]; then
    UPSTREAM_BIN="staging/agy"
  else
    die "Could not find extracted binary in staging/"
  fi
fi

# Determine build version for compilation macro
latest_version="${latest_version:-}"

# Prefer an explicit version supplied by the caller.
if [[ -z "$latest_version" && -n "${AGY_VERSION:-}" ]]; then
  latest_version="$AGY_VERSION"
fi

# For local binaries, try executing the artifact itself to read the version.
if [[ -z "$latest_version" && "$using_local_upstream" -eq 1 ]]; then
  if [[ -f "$UPSTREAM_BIN" && -x "$UPSTREAM_BIN" ]]; then
    if bin_version=$("$UPSTREAM_BIN" --version 2>/dev/null); then
      if [[ "$bin_version" =~ v?([0-9]+\.[0-9]+\.[0-9]+([-.+_A-Za-z0-9]*)?) ]]; then
        latest_version="${BASH_REMATCH[1]}"
      fi
    fi
  fi
fi

# Automatic downloads may use the manifest as the source of truth.
if [[ -z "$latest_version" && "$using_local_upstream" -eq 0 ]]; then
  info "Querying manifest for build version..."
  if manifest_data=$(curl -fsSL "$MANIFEST_URL" 2>/dev/null); then
    manifest_version=$(echo "$manifest_data" | jq -r .version 2>/dev/null)
    if [[ -n "$manifest_version" && "$manifest_version" != "null" ]]; then
      latest_version="$manifest_version"
    fi
  fi
fi

# Local builds must not be stamped with an unrelated live release version.
if [[ -z "$latest_version" && "$using_local_upstream" -eq 1 ]]; then
  die "Could not determine version for local upstream binary. Set AGY_VERSION to the supplied binary's release version."
fi

# Use the legacy default only if automatic version resolution fails.
if [[ -z "$latest_version" ]]; then
  latest_version="1.0.2"
fi
info "Resolved build version: v$latest_version"

# Apply VA39 memory patches to generate bin/agy.va39.
info "Applying VA39 structural memory allocation patches..."
python3 - "$UPSTREAM_BIN" "bin/agy.va39" <<'PY'
import sys, shutil, struct, pathlib
src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
shutil.copyfile(src, dst)
data = bytearray(dst.read_bytes())
def get(off): return struct.unpack_from("<I", data, off)[0]
def put(off, word): struct.pack_into("<I", data, off, word)

lo, hi = 0, len(data)
ubfx_count = lsl_count = mask_count = mmap_count = faccessat2_count = 0
for off in range(lo, hi, 4):
    w = get(off)
    if (w & 0x7F800000) == 0x53000000:
        immr, imms = (w >> 16) & 0x3F, (w >> 10) & 0x3F
        if immr == 42 and imms == 44:
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (35 << 16) | (37 << 10)); ubfx_count += 1
        elif immr == 22 and imms == 21:
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (29 << 16) | (28 << 10)); lsl_count += 1
for off in range(lo, hi - 4, 4):
    if get(off) == 0x92D3800A and get(off + 4) == 0xF2E0000A:
        put(off, 0x9280000A); put(off + 4, 0xD35DFD4A); mask_count += 1
for off in range(lo, hi, 4):
    if get(off) == 0xF2E00029: put(off, 0xD3596129); mmap_count += 1
word_rewrites = {
    0xD2C20009: 0xD2C00409, 0xD2C2000A: 0xD2C0040A, 0xF2C20008: 0xF2DFF408,
    0xF2C20009: 0xF2DFF409, 0xD2C10009: 0xD2C00209, 0xD2C1000A: 0xD2C0020A,
    0xF2C38008: 0xF2DFF708, 0xF2C38009: 0xF2DFF709, 0x92560A6C: 0x925D0A6C,
    0x92560A6A: 0x925D0A6A, 0xD2C3000D: 0xD2C0060D, 0xD2C3000C: 0xD2C0060C,
    0xD2C08008: 0xD2C00108,
}
for off in range(lo, hi, 4):
    w = get(off)
    if w in word_rewrites: put(off, word_rewrites[w])
for off in range(0, len(data) - 12, 4):
    if get(off) == 0xAA1F03E5 and get(off + 4) == 0xAA1F03E6 and get(off + 8) == 0xD28036E0 and (get(off + 12) & 0xFC000000) == 0x94000000:
        put(off + 8, 0xD2800600); faccessat2_count += 1
dst.write_bytes(data)
dst.chmod(0o755)
print(f"Patched parameters: ubfx={ubfx_count}, lsl={lsl_count}, mask={mask_count}, mmap={mmap_count}, faccessat2={faccessat2_count}")
PY
ok "Patched binary generated: bin/agy.va39"

# Compile the dynamic mmap interposer.
info "Compiling mmap VA39 compatibility layer as a shared library..."
if [[ -n "${TERMUX_VERSION:-}" ]]; then
  echo ""
  echo " [!] WARNING: You are building inside native Termux. The generated"
  echo "     libmmap_va39_fix.so will be linked against Android's Bionic libc."
  echo "     This binary will be bundled into the bootstrapper, but it will"
  echo "     NOT work inside a glibc PRoot environment."
  echo "     For PRoot support, run build.sh inside a glibc PRoot distro."
  echo ""
fi
mkdir -p lib
if ! "$local_cc" -O2 -fPIC -shared -o lib/libmmap_va39_fix.so lib/mmap_va39_fix.c -ldl; then
  die "Compilation of lib/mmap_va39_fix.c failed."
fi

# Generate the embedded byte header for the interposer.
info "Generating embedded byte header for dynamic interposer preloading..."
python3 -c '
import pathlib
so_path = pathlib.Path("lib/libmmap_va39_fix.so")
if not so_path.exists():
    raise FileNotFoundError("libmmap_va39_fix.so not found")
so_data = so_path.read_bytes()
hex_bytes = ", ".join(f"0x{b:02x}" for b in so_data)
pathlib.Path("lib/mmap_va39_fix_bytes.h").write_text(
    "// clang-format off\n"
    "#include <stddef.h>\n"
    f"static const unsigned char mmap_va39_fix_so[] = {{ {hex_bytes} }};\n"
    f"static const size_t mmap_va39_fix_so_len = {len(so_data)};\n"
    "// clang-format on\n"
)
'

# Compile the native C bootstrapper with the embedded interposer.
info "Compiling native C bootstrapper with embedded interposer..."
if ! "$local_cc" -O2 -DAGY_TERMUX_VERSION="\"$latest_version\"" -o bin/agy lib/agy_helper.c; then
  die "Compilation of lib/agy_helper.c failed."
fi

chmod +x bin/agy
ok "Native bootstrapper compiled successfully with embedded compatibility layer."
