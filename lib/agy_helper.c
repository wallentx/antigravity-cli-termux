#include <ctype.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    if (written < 0 || (size_t)written >= sizeof(cmd)) {
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
            if (written < 0 || (size_t)written >= sizeof(update_cmd)) {
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

int main(int argc, char **argv) {
    // 1. Clear conflicting Android Bionic preloads and search paths
    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");

    // 2. Set dynamic Go resolver and SSL configurations
    setenv("GODEBUG", "netdns=cgo", 1);
    setenv("SSL_CERT_FILE", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);

    // 3. Resolve executable directory
    char exec_path[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
    if (len == -1) {
        return 1;
    }
    exec_path[len] = '\0';
    char *dir = dirname(exec_path);

    // 4. Intercept 'update' subcommand
    if (argc >= 2 && strcmp(argv[1], "update") == 0) {
        check_and_perform_update(dir);
        return 0;
    }

    // 5. Construct relocatable paths relative to our executable's location
    char lib_path[PATH_MAX * 2];
    char patched_bin[PATH_MAX];
    char *loader = "/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1";

    // lib_path: <exec_dir>/../lib:/data/data/com.termux/files/usr/glibc/lib
    int written = snprintf(lib_path, sizeof(lib_path),
                           "%s/../lib:/data/data/com.termux/files/usr/glibc/lib", dir);
    if (written < 0 || (size_t)written >= sizeof(lib_path)) {
        return 1;
    }

    // patched_bin: <exec_dir>/agy.va39
    written = snprintf(patched_bin, sizeof(patched_bin), "%s/agy.va39", dir);
    if (written < 0 || (size_t)written >= sizeof(patched_bin)) {
        return 1;
    }

    // 6. Construct argument array
    size_t new_argc = (size_t)argc + 4U;
    char **new_argv = malloc(new_argc * sizeof(*new_argv));
    if (!new_argv) {
        return 1;
    }

    new_argv[0] = loader;
    new_argv[1] = "--library-path";
    new_argv[2] = lib_path;
    new_argv[3] = patched_bin;

    for (int i = 1; i < argc; i++) {
        new_argv[(size_t)i + 3U] = argv[i];
    }
    new_argv[(size_t)argc + 3U] = NULL;

    // 7. Execute glibc loader
    execv(loader, new_argv);

    free(new_argv);
    return 1;
}
