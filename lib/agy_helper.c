#include <asm/hwcap.h>
#include <ctype.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include "mmap_va39_fix_bytes.h"

#ifndef HWCAP_ATOMICS
#define HWCAP_ATOMICS (1 << 8)
#endif

#ifndef AGY_TERMUX_VERSION
#define AGY_TERMUX_VERSION "1.0.2"
#endif

static int agy_is_valid_release_tag(const char *tag) {
    if (tag == NULL || tag[0] == '\0' || tag[0] == '-') {
        return 0;
    }

    for (const unsigned char *cursor = (const unsigned char *)tag; *cursor != '\0'; cursor++) {
        if (!isalnum(*cursor) && *cursor != '.' && *cursor != '_' && *cursor != '-') {
            return 0;
        }
    }

    return 1;
}

static void print_update_usage(void) {
    printf("Usage: agy update [options]\n\n"
           "Options:\n"
           "  -y, --yes, --auto  Apply updates without prompting\n"
           "  -h, --help         Show this help message\n\n"
           "Environment:\n"
           "  AGY_AUTO_UPDATE=1  Apply updates without prompting\n");
}

static int should_perform_update(int auto_update) {
    if (auto_update) {
        printf("[agy-termux] Proceeding with automatic update (non-interactive)...\n");
        return 1;
    }

    if (!isatty(STDIN_FILENO)) {
        printf("[agy-termux] Error: standard input is not a TTY and auto-update is not enabled.\n");
        printf("[agy-termux] Run `agy update -y` or set AGY_AUTO_UPDATE=1 for non-interactive "
               "updates.\n");
        return 0;
    }

    for (;;) {
        printf("[agy-termux] Would you like to update now? [Y/n]: ");
        (void)fflush(stdout);

        char response_line[64] = {0};
        if (fgets(response_line, sizeof(response_line), stdin) == NULL) {
            return 0;
        }
        if (strchr(response_line, '\n') == NULL) {
            int ch = 0;
            while ((ch = getchar()) != '\n' && ch != EOF) {
            }
        }

        if (response_line[0] == '\n' || response_line[0] == '\0') {
            return 1;
        }
        if (response_line[0] == 'y' || response_line[0] == 'Y') {
            return 1;
        }
        if (response_line[0] == 'n' || response_line[0] == 'N') {
            return 0;
        }

        printf("[agy-termux] Invalid selection. Enter y or n.\n");
    }
}

// Helper to query your fork's latest release version via GitHub API and update in-place
void check_and_perform_update(const char *dir, int auto_update) {
    printf("[agy-termux] Querying latest release from wallentx/antigravity-cli-termux...\n");

    // Formulate a secure curl command to query the GitHub Releases API
    char cmd[512];
    int written = snprintf(
        cmd, sizeof(cmd),
        "curl -fsSL -H \"User-Agent: Termux-Agy\" "
        "https://api.github.com/repos/wallentx/antigravity-cli-termux/releases/latest | rg -o "
        "'\"tag_name\"\\s*:\\s*\"[^\"]*' | cut -d'\"' -f4");
    if (written < 0 || written >= (int)sizeof(cmd)) {
        printf("[agy-termux] Error: Could not construct update check command.\n");
        return;
    }

    // Intentionally uses the shell for the release-query pipeline.
    // NOLINTNEXTLINE(bugprone-command-processor,cert-env33-c)
    FILE *fp = popen(cmd, "r");
    if (!fp) {
        printf("[agy-termux] Error: Could not check for updates.\n");
        return;
    }

    char latest_tag[64] = {0};
    if (fgets(latest_tag, sizeof(latest_tag) - 1, fp) != NULL) {
        // Strip trailing newline
        latest_tag[strcspn(latest_tag, "\r\n")] = '\0';
    }
    pclose(fp);

    if (strlen(latest_tag) == 0) {
        printf("[agy-termux] Error: Failed to parse latest release tag from GitHub.\n");
        return;
    }
    if (!agy_is_valid_release_tag(latest_tag)) {
        printf("[agy-termux] Error: Latest release tag contains unsupported characters.\n");
        return;
    }

    // Clean version representations (e.g. "v1.0.2" -> "1.0.2")
    const char *clean_latest = (latest_tag[0] == 'v') ? latest_tag + 1 : latest_tag;
    const char *clean_current =
        (AGY_TERMUX_VERSION[0] == 'v') ? &AGY_TERMUX_VERSION[1] : AGY_TERMUX_VERSION;

    printf("[agy-termux] Current standalone version: v%s\n", clean_current);
    printf("[agy-termux] Latest available version : v%s\n", clean_latest);

    if (strcmp(clean_latest, clean_current) != 0) {
        printf("\n[agy-termux] A new update (v%s) is available!\n", clean_latest);

        if (should_perform_update(auto_update)) {
            printf("\n[agy-termux] Downloading and applying standalone update...\n");

            // Runs a subshell command to download into a staging directory, then replace only
            // the live twin binaries. Avoid extracting the archive over an existing bin symlink.
            char update_cmd[2048];
            written = snprintf(
                update_cmd, sizeof(update_cmd),
                "tmp=$(mktemp -d \"${TMPDIR:-%s/../tmp}/agy-update.XXXXXX\") && "
                "trap 'rm -rf \"$tmp\"' EXIT && "
                "curl -fsSL -o \"$tmp/antigravity-termux-standalone.tar.gz\" "
                "\"https://github.com/wallentx/antigravity-cli-termux/releases/download/%s/"
                "antigravity-termux-standalone.tar.gz\" && "
                "tar -xzf \"$tmp/antigravity-termux-standalone.tar.gz\" -C \"$tmp\" "
                "agy agy.va39 && "
                "install -m 0755 \"$tmp/agy\" \"%s/agy\" && "
                "install -m 0755 \"$tmp/agy.va39\" \"%s/agy.va39\"",
                dir, latest_tag, dir, dir);
            if (written < 0 || written >= (int)sizeof(update_cmd)) {
                printf("[agy-termux] Error: Could not construct update command.\n");
                return;
            }

            // Intentionally uses the shell so the update can run as one transactional command.
            // NOLINTNEXTLINE(bugprone-command-processor,cert-env33-c,cert-err34-c,cert-str02-c)
            int status = system(update_cmd);
            if (status == 0) {
                printf("[agy-termux] Update completed successfully! Please restart the CLI.\n");
            } else {
                printf("[agy-termux] Error: Update failed during download or extraction.\n");
            }
        } else {
            printf("[agy-termux] Update cancelled.\n");
        }
    } else {
        printf("[agy-termux] You are already up to date with the latest standalone release.\n");
    }
}

static int is_update_help_flag(const char *arg) {
    return strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0;
}

static int is_update_auto_flag(const char *arg) {
    return strcmp(arg, "-y") == 0 || strcmp(arg, "--yes") == 0 || strcmp(arg, "--auto") == 0;
}

static int update_command_requests_help(int argc, char **argv) {
    for (int i = 2; i < argc; i++) {
        if (is_update_help_flag(argv[i])) {
            return 1;
        }
    }

    return 0;
}

static int is_update_command(int argc, char **argv) {
    return argc >= 2 && strcmp(argv[1], "update") == 0;
}

static int env_requests_auto_update(void) {
    const char *env_auto = getenv("AGY_AUTO_UPDATE");

    return env_auto != NULL && (strcmp(env_auto, "1") == 0 || strcmp(env_auto, "true") == 0);
}

static int handle_update_command(const char *dir, int argc, char **argv) {
    int auto_update = env_requests_auto_update();

    for (int i = 2; i < argc; i++) {
        if (is_update_help_flag(argv[i])) {
            print_update_usage();
            return 0;
        }
        if (is_update_auto_flag(argv[i])) {
            auto_update = 1;
        }
    }

    check_and_perform_update(dir, auto_update);
    return 0;
}

static int is_native_termux(void) {
    const char *termux_version = getenv("TERMUX_VERSION");
    const char *prefix = getenv("PREFIX");
    char bin_path[PATH_MAX];
    int written = 0;

    if (termux_version == NULL || termux_version[0] == '\0') {
        return 0;
    }
    if (prefix == NULL || prefix[0] == '\0') {
        return 0;
    }
    written = snprintf(bin_path, sizeof(bin_path), "%s/bin", prefix);
    if (written < 0 || written >= (int)sizeof(bin_path)) {
        return 0;
    }
    if (access(bin_path, F_OK) != 0) {
        return 0;
    }

    return 1;
}

static int require_resolver_config(const char *prefix, int is_termux) {
    char resolv_path[PATH_MAX];
    int written;
    if (is_termux) {
        written = snprintf(resolv_path, sizeof(resolv_path), "%s/etc/resolv.conf", prefix);
    } else {
        written = snprintf(resolv_path, sizeof(resolv_path), "/etc/resolv.conf");
    }
    if (written < 0 || written >= (int)sizeof(resolv_path)) {
        return 0;
    }

    if (access(resolv_path, R_OK) != 0) {
        (void)fprintf(stderr, "[agy-compat] Missing resolver configuration: %s\n", resolv_path);
        if (is_termux) {
            (void)fprintf(stderr, "[agy-termux] Install it with: pkg install resolv-conf\n");
        }
        (void)fprintf(stderr,
                      "[agy-compat] Without this file, login and OAuth network requests may "
                      "fail.\n");
        return 0;
    }

    return 1;
}

static int resolve_qemu_for_cpu(const char *prefix, char *qemu_path, size_t qemu_path_len,
                                const char **qemu) {
    unsigned long hwcap = getauxval(AT_HWCAP);

    *qemu = NULL;
    if ((hwcap & HWCAP_ATOMICS) != 0) {
        return 1;
    }

    int qemu_written = snprintf(qemu_path, qemu_path_len, "%s/bin/qemu-aarch64", prefix);
    if (qemu_written > 0 && (size_t)qemu_written < qemu_path_len && access(qemu_path, F_OK) == 0) {
        *qemu = qemu_path;
        return 1;
    }

    (void)fprintf(stderr, "[agy-termux] CPU lacks LSE atomics, and qemu-aarch64 was not found.\n");
    (void)fprintf(stderr, "[agy-termux] You may need to install the qemu-user-aarch64 package.\n");
    return 0;
}

static const char *unpack_mmap_fixer(void) {
    static char unpacked_path[PATH_MAX];
    const char *tmp = getenv("TMPDIR");
    if (!tmp || tmp[0] == '\0') {
        tmp = "/tmp";
    }

    int written = snprintf(unpacked_path, sizeof(unpacked_path), "%s/libmmap_va39_fix.so", tmp);
    if (written < 0 || written >= (int)sizeof(unpacked_path)) {
        return NULL;
    }

    struct stat st;
    if (stat(unpacked_path, &st) == 0 && st.st_size == (off_t)mmap_va39_fix_so_len) {
        return unpacked_path;
    }

    FILE *fp = fopen(unpacked_path, "wb");
    if (!fp) {
        return NULL;
    }

    size_t written_bytes = fwrite(mmap_va39_fix_so, 1, mmap_va39_fix_so_len, fp);

    if (fclose(fp) != 0 || written_bytes != mmap_va39_fix_so_len) {
        unlink(unpacked_path);
        return NULL;
    }

    if (chmod(unpacked_path, 0755) != 0) {
        return NULL;
    }

    return unpacked_path;
}

int main(int argc, char **argv) {
    char exec_path[PATH_MAX];
    char lib_path[PATH_MAX * 3];
    char patched_bin[PATH_MAX];
    char dynamic_loader[PATH_MAX];
    char cert_path[PATH_MAX];
    char prefix_path[PATH_MAX];
    char qemu_path[PATH_MAX];
    const char *prefix = getenv("PREFIX");
    const char *loader = NULL;
    const char *dir = NULL;
    const char *qemu = NULL;
    const char *exec_target = NULL;
    const char *exec_error = NULL;
    const char *fixer_path = NULL;
    char **new_argv = NULL;
    int arg_idx = 0;
    int written = 0;
    ssize_t read_len = 0;
    int is_termux = is_native_termux();

    if (is_termux) {
        if (!resolve_qemu_for_cpu(prefix, qemu_path, sizeof(qemu_path), &qemu)) {
            return 1;
        }
        written = snprintf(prefix_path, sizeof(prefix_path), "%s", prefix);
        if (written < 0 || written >= (int)sizeof(prefix_path)) {
            return 1;
        }
        written = snprintf(dynamic_loader, sizeof(dynamic_loader), "%s/glibc/lib/ld-linux-aarch64.so.1",
                           prefix_path);
        if (written < 0 || written >= (int)sizeof(dynamic_loader)) {
            return 1;
        }
        loader = dynamic_loader;
        exec_target = loader;
        exec_error = "[agy-termux] execv failed";

        if (access(loader, F_OK) != 0) {
            (void)fprintf(stderr, "[agy-termux] Missing Termux glibc loader: %s\n", loader);
            (void)fprintf(stderr,
                          "[agy-termux] You may need to install the glibc-repo and glibc packages.\n");
            return 1;
        }
    } else {
        fixer_path = unpack_mmap_fixer();
        if (!fixer_path) {
            (void)fprintf(stderr, "[ERR] Failed to extract PRoot/Chroot compatibility layer.\n");
            return 1;
        }
        loader = "/lib/ld-linux-aarch64.so.1";
        exec_target = loader;
        exec_error = "[agy-compat] execv failed";
        if (access(loader, F_OK) != 0) {
            (void)fprintf(stderr, "[agy-compat] Missing glibc loader: %s\n", loader);
            return 1;
        }
    }

    // Clear conflicting Android Bionic preloads and search paths.
    if (is_termux) {
        unsetenv("LD_PRELOAD");
    }
    unsetenv("LD_LIBRARY_PATH");

    // Set dynamic Go resolver and SSL configuration.
    setenv("GODEBUG", "netdns=cgo", 1);
    if (is_termux) {
        written = snprintf(cert_path, sizeof(cert_path), "%s/etc/tls/cert.pem", prefix_path);
        if (written < 0 || written >= (int)sizeof(cert_path)) {
            return 1;
        }
        setenv("SSL_CERT_FILE", cert_path, 1);
    } else if (access("/etc/ssl/certs/ca-certificates.crt", F_OK) == 0) {
        setenv("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt", 1);
    }

    read_len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
    if (read_len < 0 || read_len >= (ssize_t)sizeof(exec_path)) {
        return 1;
    }
    exec_path[read_len] = '\0';
    dir = dirname(exec_path);

    if (is_update_command(argc, argv)) {
        if (update_command_requests_help(argc, argv)) {
            return handle_update_command(dir, argc, argv);
        }
        if (!require_resolver_config(prefix_path, is_termux)) {
            return 1;
        }
        return handle_update_command(dir, argc, argv);
    }

    if (!require_resolver_config(prefix_path, is_termux)) {
        return 1;
    }

    // Construct relocatable library search path.
    if (is_termux) {
        written = snprintf(lib_path, sizeof(lib_path), "%s/../lib:%s/glibc/lib", dir, prefix_path);
    } else {
        written = snprintf(lib_path, sizeof(lib_path), "%s/../lib:/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu", dir);
    }
    if (written < 0 || written >= (int)sizeof(lib_path)) {
        return 1;
    }

    // Construct path to the patched binary.
    written = snprintf(patched_bin, sizeof(patched_bin), "%s/agy.va39", dir);
    if (written < 0 || written >= (int)sizeof(patched_bin)) {
        return 1;
    }

    // We allocate enough space for: qemu + loader + "--preload" + fixer_path + "--library-path" + lib_path
    // + patched_bin + user args + NULL
    int new_argc = argc + 10;
    new_argv = malloc((size_t)new_argc * sizeof(*new_argv));
    if (!new_argv) {
        return 1;
    }

    arg_idx = 0;
    if (qemu) {
        new_argv[arg_idx++] = (char *)qemu;
        exec_target = qemu;
        exec_error = "[agy-termux] execv (qemu) failed";
    }
    new_argv[arg_idx++] = (char *)loader;
    if (fixer_path) {
        new_argv[arg_idx++] = "--preload";
        new_argv[arg_idx++] = (char *)fixer_path;
    }
    new_argv[arg_idx++] = "--library-path";
    new_argv[arg_idx++] = lib_path;
    new_argv[arg_idx++] = patched_bin;

    for (int i = 1; i < argc; i++) {
        new_argv[arg_idx++] = argv[i];
    }
    new_argv[arg_idx] = NULL;

    // NOLINTNEXTLINE(clang-analyzer-optin.taint.GenericTaint)
    if (execv(exec_target, new_argv) == -1) {
        perror(exec_error);
        free(new_argv);
        return 1;
    }
}
