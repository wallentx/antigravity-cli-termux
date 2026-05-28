# PRoot Distro and 39-Bit Virtual Address Space Compatibility

## Purpose
This document explains the runtime interposer and environment-aware bootstrapper architecture implemented to support executing the Antigravity CLI within non-native Termux environments (e.g., guest PRoot/Chroot distributions on Android).

## Problem: 39-Bit Virtual Address Space Limits
The upstream dynamic binary utilizes Google's `TCMalloc` allocator, which assumes a standard 48-bit Virtual Address (VA) space.

However, many ARM64 Android kernels limit user space to a 39-bit VA space. When TCMalloc makes `mmap` calls specifying a high hint address (e.g., above `2^39`), the call fails on these kernels, triggering an immediate abort:
```text
FATAL ERROR: Out of memory trying to allocate internal tcmalloc data
MmapAligned() failed - unable to allocate with tag (hint=0x2f4c00000000, size=1073741824)
```

## Solution: Runtime Mmap Interposition
Because the upstream Go binary is precompiled, system calls made during its execution cannot be modified at source level. The compatibility layer intercepts these calls at the dynamic loading boundary.

### 1. The Interposer (`lib/mmap_va39_fix.c`)
A minimal shared library intercepts dynamic `mmap` calls at runtime. If a requested hint address exceeds the 39-bit boundary (`1ULL << 39`), the interposer clears the hint (setting it to `NULL`). This redirects the kernel to allocate memory at a valid, lower virtual address, preventing the TCMalloc crash.

### 2. Transient Build-Time Embedding
To keep the release archive restricted strictly to the `bin/` directory, the interposer is embedded directly inside the bootstrapper rather than being packaged as a separate file in the release archive:
* **Build-Time**: `build.sh` compiles `lib/mmap_va39_fix.c` to `libmmap_va39_fix.so`, converts the raw binary data into a C byte array header (`lib/mmap_va39_fix_bytes.h`), and compiles it into the `bin/agy` executable.
* **Git Hygiene**: The generated header and intermediate `.so` are git-ignored to keep the repository history clean.

### 3. Just-In-Time Extraction & Preloading (`lib/agy_helper.c`)
At runtime, the bootstrapper `bin/agy` executes the following sequence:
1. **Environment Detection**: Detects if execution is running natively inside Termux or within a guest PRoot/Chroot distribution.
2. **Dynamic Unpacking**: If running in a guest PRoot/Chroot distribution, the bootstrapper extracts the embedded `.so` bytes from memory to a writable temporary directory (prioritizing `$TMPDIR` before falling back to `/tmp`). Writing is skipped if the file already exists with matching size.
3. **Preload Injection**: Appends the extracted `.so` path to the glibc loader `--preload` argument and configures relocatable library search paths (e.g., dynamically adding `/lib` and `/usr/lib`) before executing `execv`.
