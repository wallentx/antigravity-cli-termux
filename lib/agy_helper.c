#include <ctype.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/auxv.h>
#include <asm/hwcap.h>

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

// Helper to query your fork's latest release version via GitHub API and update in-place
void check_and_perform_update(const char *dir) {
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
        printf("[agy-termux] Would you like to update now? [y/N]: ");
        (void)fflush(stdout);

        char response = 'n';
        char response_line[8] = {0};
        if (fgets(response_line, sizeof(response_line), stdin) != NULL) {
            response = response_line[0];
        }
        if (response == 'y' || response == 'Y') {
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

static void print_non_termux_message(void) {
    (void)fprintf(stderr, "[agy-termux] This standalone port is only for native Termux.\n"
                          "[agy-termux] PRoot environments can use Google's official "
                          "Antigravity CLI binary directly.\n"
                          "[agy-termux] Install it with:\n"
                          "  curl -fsSL https://antigravity.google/cli/install.sh | bash\n");
}

int main(int argc, char **argv) {
    char exec_path[PATH_MAX];
    char lib_path[PATH_MAX * 3];
    char patched_bin[PATH_MAX];
    char dynamic_loader[PATH_MAX];
    char cert_path[PATH_MAX];
    char prefix_path[PATH_MAX];
    const char *prefix = getenv("PREFIX");
    const char *loader = NULL;
    const char *dir = NULL;
    const char *qemu = NULL;
    char **new_argv = NULL;
    int has_lse = 0;
    int arg_idx = 0;
    int written = 0;
    ssize_t read_len = 0;

    if (!is_native_termux()) {
        print_non_termux_message();
        return 1;
    }

    // Detect LSE support
    has_lse = (getauxval(AT_HWCAP) & HWCAP_ATOMICS);
    if (!has_lse) {
        // Find QEMU path in Termux prefix
        char qemu_path[PATH_MAX];
        int qemu_written = snprintf(qemu_path, sizeof(qemu_path), "%s/bin/qemu-aarch64", prefix);
        if (qemu_written > 0 && qemu_written < (int)sizeof(qemu_path)) {
            if (access(qemu_path, F_OK) == 0) {
                static char static_qemu_path[PATH_MAX];
                strcpy(static_qemu_path, qemu_path);
                qemu = static_qemu_path;
            }
        }
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

    if (access(loader, F_OK) != 0) {
        (void)fprintf(stderr, "[agy-termux] Missing Termux glibc loader: %s\n", loader);
        (void)fprintf(stderr,
                      "[agy-termux] You may need to install the glibc-repo and glibc packages.\n");
        return 1;
    }

    // Clear conflicting Android Bionic preloads and search paths.
    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");

    // Set dynamic Go resolver and SSL configuration.
    setenv("GODEBUG", "netdns=cgo", 1);
    written = snprintf(cert_path, sizeof(cert_path), "%s/etc/tls/cert.pem", prefix_path);
    if (written < 0 || written >= (int)sizeof(cert_path)) {
        return 1;
    }
    setenv("SSL_CERT_FILE", cert_path, 1);

    read_len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
    if (read_len < 0 || read_len >= (ssize_t)sizeof(exec_path)) {
        return 1;
    }
    exec_path[read_len] = '\0';
    dir = dirname(exec_path);

    if (argc >= 2 && strcmp(argv[1], "update") == 0) {
        check_and_perform_update(dir);
        return 0;
    }

    // Construct relocatable library search path for native Termux glibc.
    written = snprintf(lib_path, sizeof(lib_path), "%s/../lib:%s/glibc/lib", dir, prefix_path);
    if (written < 0 || written >= (int)sizeof(lib_path)) {
        return 1;
    }

    // Construct path to the patched binary
    written = snprintf(patched_bin, sizeof(patched_bin), "%s/agy.va39", dir);
    if (written < 0 || written >= (int)sizeof(patched_bin)) {
        return 1;
    }

    // We allocate enough space for: qemu + loader + "--library-path" + lib_path
    // + patched_bin + user args + NULL
    int new_argc = argc + 6;
    new_argv = malloc((size_t)new_argc * sizeof(*new_argv));
    if (!new_argv) {
        return 1;
    }

    arg_idx = 0;
    if (qemu) {
        new_argv[arg_idx++] = (char *)qemu;
    }
    new_argv[arg_idx++] = (char *)loader;
    new_argv[arg_idx++] = "--library-path";
    new_argv[arg_idx++] = lib_path;
    new_argv[arg_idx++] = patched_bin;

    for (int i = 1; i < argc; i++) {
        new_argv[arg_idx++] = argv[i];
    }
    new_argv[arg_idx] = NULL;

    // NOLINTNEXTLINE(clang-analyzer-optin.taint.GenericTaint)
    if (qemu) {
        if (execv(qemu, new_argv) == -1) {
            perror("[agy-termux] execv (qemu) failed");
            free(new_argv);
            return 1;
        }
    } else {
        if (execv(loader, new_argv) == -1) {
            perror("[agy-termux] execv failed");
            free(new_argv);
            return 1;
        }
    }
}
