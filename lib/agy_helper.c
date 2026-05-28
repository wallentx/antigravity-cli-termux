#include "mmap_va39_fix_bytes.h"
#include <ctype.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

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

            // Runs a subshell command to download the new tar.gz, extract it, and overwrite files
            // Uses dir/.. to target the parent directory containing bin/ and lib/
            char update_cmd[1024];
            written = snprintf(
                update_cmd, sizeof(update_cmd),
                "cd \"%s/..\" && "
                "curl -fsSLO "
                "\"https://github.com/wallentx/antigravity-cli-termux/releases/download/%s/"
                "antigravity-termux-standalone.tar.gz\" && "
                "tar -xzf antigravity-termux-standalone.tar.gz && "
                "rm antigravity-termux-standalone.tar.gz",
                dir, latest_tag);
            if (written < 0 || written >= (int)sizeof(update_cmd)) {
                printf("[agy-termux] Error: Could not construct update command.\n");
                return;
            }

            // Intentionally uses the shell so the update can run as one transactional command.
            // NOLINTNEXTLINE(bugprone-command-processor,cert-env33-c)
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

// Returns the path of the unpacked .so on success, NULL on failure
const char *unpack_mmap_fixer(void) {
    static char unpacked_path[PATH_MAX];

    // Resolve temp directory priority: $TMPDIR -> /tmp
    const char *tmp = getenv("TMPDIR");
    if (!tmp || tmp[0] == '\0') {
        tmp = "/tmp";
    }

    int written = snprintf(unpacked_path, sizeof(unpacked_path), "%s/libmmap_va39_fix.so", tmp);
    if (written < 0 || written >= (int)sizeof(unpacked_path)) {
        return NULL;
    }

    // Check if the file already exists and matches the expected size to avoid redundant writes
    struct stat st;
    if (stat(unpacked_path, &st) == 0 && st.st_size == (off_t)mmap_va39_fix_so_len) {
        return unpacked_path;
    }

    // Unpack the bytes
    FILE *fp = fopen(unpacked_path, "wb");
    if (!fp) {
        return NULL;
    }

    size_t written_bytes = fwrite(mmap_va39_fix_so, 1, mmap_va39_fix_so_len, fp);

    if (fclose(fp) != 0 || written_bytes != mmap_va39_fix_so_len) {
        unlink(unpacked_path);
        return NULL;
    }

    // Ensure it is executable
    if (chmod(unpacked_path, 0755) != 0) {
        return NULL;
    }

    return unpacked_path;
}

int main(int argc, char **argv) {
    // 1. Consolidate variables at top to avoid shadowing (-Wshadow)
    char exec_path[PATH_MAX];
    char lib_path[PATH_MAX * 3];
    char patched_bin[PATH_MAX];
    const char *loader = "/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1";
    const char *dir = NULL;
    const char *fixer_path = NULL;
    char **new_argv = NULL;
    int is_termux = 0;
    int arg_idx = 0;
    int written = 0;
    ssize_t read_len = 0;

    // Detect if running in native Termux
    is_termux = (access("/data/data/com.termux/files/usr/bin", F_OK) == 0);

    // 2. Clear conflicting Android Bionic preloads and search paths
    if (is_termux) {
        unsetenv("LD_PRELOAD");
    }
    unsetenv("LD_LIBRARY_PATH");

    // 3. Set dynamic Go resolver and SSL configurations
    setenv("GODEBUG", "netdns=cgo", 1);
    if (is_termux) {
        setenv("SSL_CERT_FILE", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);
    } else if (access("/etc/ssl/certs/ca-certificates.crt", F_OK) == 0) {
        setenv("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt", 1);
    }

    // 4. Resolve executable directory
    read_len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
    if (read_len == -1) {
        return 1;
    }
    exec_path[read_len] = '\0';
    dir = dirname(exec_path);

    // 5. Intercept 'update' subcommand
    if (argc >= 2 && strcmp(argv[1], "update") == 0) {
        check_and_perform_update(dir);
        return 0;
    }

    // 6. Handle interposer unpacking in non-Termux (chroot) environments
    if (!is_termux) {
        fixer_path = unpack_mmap_fixer();
        if (!fixer_path) {
            (void)fprintf(stderr,
                          "[ERR] Failed to extract PRoot compatibility layer. Please check /tmp "
                          "permissions.\n");
            return 1;
        }
    }

    // 7. Resolve dynamic loader path
    if (access(loader, F_OK) != 0) {
        loader = "/lib/ld-linux-aarch64.so.1";
    }

    // 8. Construct relocatable library search path
    if (is_termux) {
        written = snprintf(lib_path, sizeof(lib_path),
                           "%s/../lib:/data/data/com.termux/files/usr/glibc/lib", dir);
    } else {
        written = snprintf(lib_path, sizeof(lib_path),
                           "%s/../lib:/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:/lib64:/"
                           "usr/lib64:/lib:/usr/lib",
                           dir);
    }
    if (written < 0 || written >= (int)sizeof(lib_path)) {
        return 1;
    }

    // Construct path to the patched binary
    written = snprintf(patched_bin, sizeof(patched_bin), "%s/agy.va39", dir);
    if (written < 0 || written >= (int)sizeof(patched_bin)) {
        return 1;
    }

    // 9. Construct new argument array
    // We allocate enough space for: loader + "--preload" + fixer_path + "--library-path" + lib_path
    // + patched_bin + user args + NULL
    int new_argc = argc + 8;
    new_argv = malloc((size_t)new_argc * sizeof(*new_argv));
    if (!new_argv) {
        return 1;
    }

    arg_idx = 0;
    new_argv[arg_idx++] = (char *)loader;

    // Inject the interposer dynamic library as a preload if unpacked successfully
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

    // 10. Execute the glibc dynamic loader
    if (execv(loader, new_argv) == -1) {
        perror("[agy-termux] execv failed");
        free(new_argv);
        return 1;
    }
}
