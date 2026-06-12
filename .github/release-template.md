Automated standalone Termux build of the Antigravity CLI v{{VERSION}}.

> [!IMPORTANT]
> **Twin-Binary Requirement:** The release package contains **two** binaries: `agy` and `agy.va39`.
> * `agy.va39` is the core patched engine.
> * `agy` is the native Bionic C bootstrapper.
> **Always execute the `agy` binary.** It automatically clears conflicts and executes the core engine. You **must** keep both files in the same directory for the bootstrapper to run successfully.

### 🔀 Standalone Fork Changelog
{{FORK_CHANGELOG}}

### ⬆️ Upstream Changelog (v{{VERSION}})

{{UPSTREAM_NOTES}}

### 📦 Installation
To install this release into native Termux, use the installer:
```bash
curl -fsSL https://raw.githubusercontent.com/{{REPO}}/dev/install.sh | bash
```

To inspect or smoke-test the archive without installing it, extract it into a
dedicated sandbox directory instead of unpacking directly in `$HOME`:
```bash
curl -fsSLO https://github.com/{{REPO}}/releases/download/v{{VERSION}}/antigravity-termux-standalone.tar.gz
rm -rf agy-termux-standalone
mkdir -p agy-termux-standalone
tar -xzf antigravity-termux-standalone.tar.gz -C agy-termux-standalone

./agy-termux-standalone/agy --help
```

### 🔒 Cryptographic Verification
This release is signed with cryptographic build provenance. Verify it natively using the GitHub CLI:
```bash
gh attestation verify antigravity-termux-standalone.tar.gz -R {{REPO}}
```
