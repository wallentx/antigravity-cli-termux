#!/usr/bin/env python3
"""Native launcher fixtures: runtime selection, CPU fallback, environment, and updates."""

import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENV_KEYS = ("LD_PRELOAD", "LD_LIBRARY_PATH", "SSL_CERT_FILE", "GODEBUG")


class LauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix="agy-launcher-", dir=os.getenv("TMPDIR"))
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)
        compiler = os.environ.get("CC") or shutil.which("clang")
        if not compiler:
            raise RuntimeError("Native Termux clang is required")
        # Control the CPU capability without adding a test override to production.
        hwcap = cls.root / "hwcap.c"
        hwcap.write_text('''
#include <stdlib.h>
#include <string.h>
unsigned long fixture_getauxval(unsigned long type) {
    (void)type;
    const char *lse = getenv("FIXTURE_LSE");
    return lse && strcmp(lse, "0") == 0 ? 0 : 1UL << 8;
}
''')
        cls.launcher = cls.root / "launcher"
        subprocess.run([
            compiler, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
            "-Dgetauxval=fixture_getauxval", "-o", str(cls.launcher),
            str(ROOT / "lib/agy_helper.c"), str(hwcap),
        ], check=True)
        recorder = cls.root / "recorder.c"
        recorder.write_text('''
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    const char *names[] = {KEYS};
    printf("%d%c", argc, 0);
    for (int i = 0; i < argc; i++) printf("%s%c", argv[i], 0);
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        const char *value = getenv(names[i]);
        printf("%s%c", value ? value : "<unset>", 0);
    }
    const char *status = getenv("FIXTURE_EXIT");
    return status ? atoi(status) : 0;
}
'''.replace("KEYS", ", ".join('"' + key + '"' for key in ENV_KEYS)))
        cls.recorder = cls.root / "recorder"
        subprocess.run([compiler, "-o", str(cls.recorder), str(recorder)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="case with spaces ", dir=self.root)
        self.addCleanup(self.temp.cleanup)
        self.case = Path(self.temp.name)
        self.prefix = self.case / "prefix"
        self.bin = self.prefix / "bin"
        self.bin.mkdir(parents=True)
        self.loader = self.prefix / "glibc/lib/ld-linux-aarch64.so.1"
        self.aether = self.bin / "aether-run"
        self.qemu = self.bin / "qemu-aarch64"
        self.payload = self.bin / "agy.va39"
        self.payload.write_text("fixture payload")
        self.resolver = self.prefix / "etc/resolv.conf"
        self.resolver.parent.mkdir(parents=True)
        self.resolver.write_text("nameserver 127.0.0.1\n")
        self.command = self.bin / "agy"
        shutil.copy2(self.launcher, self.command)
        self.env = os.environ.copy()
        for name in list(self.env):
            if name.startswith("AGY_") or name.startswith("FIXTURE_"):
                self.env.pop(name)
        self.env.update(PREFIX=str(self.prefix), TERMUX_VERSION="fixture", FIXTURE_LSE="1",
                        LD_LIBRARY_PATH=str(self.case), GODEBUG="fixture")

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.recorder, path)

    def run_launcher(self, *args):
        # Captured pipes also ensure ordinary fixture launches cannot check for updates.
        return subprocess.run([str(self.command), *args], env=self.env,
                              capture_output=True, timeout=10)

    def invoke(self, *args, status=0):
        result = self.run_launcher(*args)
        self.assertEqual(result.returncode, status, result.stderr.decode())
        fields = result.stdout.decode().split("\0")
        argc = int(fields[0])
        env = dict(zip(ENV_KEYS, fields[argc + 1:-1]))
        self.assertEqual(env["SSL_CERT_FILE"], str(self.prefix / "etc/tls/cert.pem"))
        self.assertEqual(env["GODEBUG"], "netdns=cgo")
        return fields[1:argc + 1], env

    def assert_legacy(self, qemu=False):
        args, env = self.invoke("--version")
        expected = [str(self.loader), "--library-path", str(self.loader.parent),
                    str(self.payload), "--version"]
        if qemu:
            expected.insert(0, str(self.qemu))
        self.assertEqual(args, expected)
        self.assertEqual(env["LD_PRELOAD"], "<unset>")
        self.assertEqual(env["LD_LIBRARY_PATH"], "<unset>")

    def test_ordinary_termux_retains_legacy_loader(self):
        self.executable(self.loader)
        self.assert_legacy()

    def test_aether_without_package_loader_preserves_args_and_environment(self):
        self.executable(self.aether)
        forwarded = ["--version", "two words", "", "quote'\"", "line\nbreak"]
        args, env = self.invoke(*forwarded)
        self.assertEqual(args, [str(self.aether), "--", str(self.payload), *forwarded])
        self.assertEqual(env["LD_PRELOAD"], self.env.get("LD_PRELOAD", "<unset>"))
        self.assertEqual(env["LD_LIBRARY_PATH"], self.env["LD_LIBRARY_PATH"])

    def test_aether_symlink_is_preferred_when_both_runtimes_exist(self):
        self.aether.symlink_to(self.recorder)
        self.executable(self.loader)
        self.assertEqual(self.invoke()[0], [str(self.aether), "--", str(self.payload)])

    def test_opt_out_keeps_legacy_path(self):
        self.executable(self.aether)
        self.executable(self.loader)
        for value in ("1", "true"):
            with self.subTest(value=value):
                self.env["AGY_NO_AETHER"] = value
                self.assert_legacy()

    def test_false_opt_out_still_uses_aether(self):
        self.executable(self.aether)
        for value in ("", "0", "false"):
            with self.subTest(value=value):
                self.env["AGY_NO_AETHER"] = value
                self.assertEqual(self.invoke()[0][0], str(self.aether))

    def test_nonexecutable_aether_keeps_legacy_path(self):
        self.executable(self.loader)
        self.executable(self.aether)
        self.aether.chmod(0o644)
        self.assert_legacy()

    def test_path_lookup_does_not_select_unrelated_aether(self):
        self.executable(self.loader)
        unrelated = self.case / "unrelated"
        self.executable(unrelated / "aether-run")
        self.env["PATH"] = str(unrelated) + os.pathsep + self.env["PATH"]
        self.assert_legacy()

    def test_aether_failure_is_not_retried_through_legacy_loader(self):
        self.executable(self.aether)
        self.executable(self.loader)
        self.env["FIXTURE_EXIT"] = "37"
        self.assertEqual(self.invoke("--version", status=37)[0][0], str(self.aether))

    def test_non_lse_cpu_keeps_qemu_even_with_aether_installed(self):
        self.env["FIXTURE_LSE"] = "0"
        self.executable(self.loader)
        self.executable(self.qemu)
        self.assert_legacy(qemu=True)
        self.executable(self.aether)
        self.assert_legacy(qemu=True)

    def test_non_lse_cpu_still_requires_qemu(self):
        self.env["FIXTURE_LSE"] = "0"
        self.executable(self.aether)
        result = self.run_launcher("--version")
        self.assertEqual(result.returncode, 1)
        self.assertIn("CPU lacks LSE atomics", result.stderr.decode())

    def test_qemu_still_requires_package_loader(self):
        self.env["FIXTURE_LSE"] = "0"
        self.executable(self.qemu)
        self.executable(self.aether)
        result = self.run_launcher("--version")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Missing Termux glibc loader", result.stderr.decode())

    def test_update_help_remains_intercepted_without_resolver(self):
        self.resolver.unlink()
        for runtime in (self.loader, self.aether):
            with self.subTest(runtime=runtime):
                self.executable(runtime)
                result = self.run_launcher("update", "--help")
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertIn("AGY_AUTO_UPDATE", result.stdout.decode())
                runtime.unlink()

    def test_resolver_requirement_still_applies_to_both_runtimes(self):
        self.resolver.unlink()
        for runtime in (self.loader, self.aether):
            self.executable(runtime)
            result = self.run_launcher("--version")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Missing resolver configuration", result.stderr.decode())
            runtime.unlink()

    def test_installer_runtime_prerequisites(self):
        fixture = self.case / "install-fixture"
        fixture.write_text(f"#!{shutil.which('bash')}\nprintf '1.2.7-fixture\\n'\n")
        fixture.chmod(0o755)
        archive = self.case / "release.tar.gz"
        with tarfile.open(archive, "w:gz") as release:
            release.add(fixture, arcname="agy")
            release.add(fixture, arcname="agy.va39")
        probes = self.case / "probes"
        probes.mkdir()
        grep = probes / "grep"
        grep.write_text(
            f"#!{shutil.which('bash')}\n"
            'if [[ "$*" == "-q atomics /proc/cpuinfo" ]]; then\n'
            '  [[ "$FIXTURE_LSE" == "1" ]]\n'
            f"else exec {shlex.quote(shutil.which('grep'))} \"$@\"; fi\n"
        )
        grep.chmod(0o755)
        # Native Aether can omit the package loader; opt-out and QEMU cannot.
        scenarios = (
            (True, False, False, "0", "1", 0),
            (False, True, False, "0", "1", 0),
            (True, False, False, "1", "1", 1),
            (True, False, False, "true", "1", 1),
            (True, False, True, "0", "0", 1),
            (True, True, True, "0", "0", 0),
            (True, True, False, "0", "0", 1),
        )
        for index, (aether, legacy, qemu, disabled, lse, status) in enumerate(scenarios):
            with self.subTest(aether=aether, legacy=legacy, qemu=qemu, disabled=disabled, lse=lse):
                prefix = self.case / f"install-{index}"
                (prefix / "bin").mkdir(parents=True)
                (prefix / "etc/tls").mkdir(parents=True)
                (prefix / "etc/tls/cert.pem").write_text("fixture CA")
                (prefix / "etc/resolv.conf").write_text("nameserver 127.0.0.1\n")
                for enabled, relative in (
                    (aether, "bin/aether-run"), (legacy, "glibc/lib/ld-linux-aarch64.so.1"),
                    (qemu, "bin/qemu-aarch64"),
                ):
                    if enabled:
                        self.executable(prefix / relative)
                env = self.env | {
                    "PREFIX": str(prefix), "FIXTURE_LSE": lse, "AGY_NO_AETHER": disabled,
                    "AGY_INSTALL_URL": archive.as_uri(), "AGY_INSTALL_SKIP_LAUNCH": "1",
                    "PATH": str(probes) + os.pathsep + str(prefix / "bin") + os.pathsep + self.env["PATH"],
                }
                result = subprocess.run(["bash", str(ROOT / "install.sh")], env=env,
                                        capture_output=True, timeout=20)
                self.assertEqual(result.returncode, status, result.stdout.decode() + result.stderr.decode())
                if status == 0:
                    self.assertEqual((prefix / "bin/agy").read_bytes(), fixture.read_bytes())
                    self.assertEqual((prefix / "bin/agy.va39").read_bytes(), fixture.read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
