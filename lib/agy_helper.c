#include <asm/hwcap.h>
#include <ctype.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef HWCAP_ATOMICS
#define HWCAP_ATOMICS (1 << 8)
#endif

#ifndef AGY_TERMUX_VERSION
#define AGY_TERMUX_VERSION "1.0.2"
#endif

#define AGY_LATEST_RELEASE_URL "https://github.com/wallentx/antigravity-cli-termux/releases/latest"
#define AGY_RELEASE_TAG_URL_PREFIX                                                                 \
    "https://github.com/wallentx/antigravity-cli-termux/releases/tag/"

enum update_check_mode {
    UPDATE_CHECK_EXPLICIT,
    UPDATE_CHECK_STARTUP,
};

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

struct semantic_version {
    unsigned long core[3];
    const char *prerelease;
    size_t prerelease_length;
};

struct version_identifier {
    const char *start;
    size_t length;
    int numeric;
};

static int validate_version_identifier(int enforce_numeric_leading_zero, const char *start,
                                       size_t length) {
    int numeric = 1;

    if (length == 0) {
        return 0;
    }

    for (size_t index = 0; index < length; index++) {
        unsigned char character = (unsigned char)start[index];
        if (!isalnum(character) && character != '-') {
            return 0;
        }
        if (!isdigit(character)) {
            numeric = 0;
        }
    }

    return !(enforce_numeric_leading_zero && numeric && length > 1 && start[0] == '0');
}

static int validate_identifier_list(int enforce_numeric_leading_zero, const char *start,
                                    size_t length) {
    size_t identifier_start = 0;

    if (length == 0) {
        return 0;
    }

    for (;;) {
        size_t identifier_end = identifier_start;
        while (identifier_end < length && start[identifier_end] != '.') {
            identifier_end++;
        }

        if (!validate_version_identifier(enforce_numeric_leading_zero, start + identifier_start,
                                         identifier_end - identifier_start)) {
            return 0;
        }
        if (identifier_end == length) {
            return 1;
        }
        identifier_start = identifier_end + 1;
    }
}

static int parse_core_component(const char **cursor, unsigned long *value) {
    if (!isdigit((unsigned char)**cursor)) {
        return 0;
    }
    if (**cursor == '0' && isdigit((unsigned char)(*cursor)[1])) {
        return 0;
    }

    errno = 0;
    char *end = NULL;
    *value = strtoul(*cursor, &end, 10);
    if (errno == ERANGE || end == *cursor) {
        return 0;
    }

    *cursor = end;
    return 1;
}

static int parse_semantic_version(const char *text, struct semantic_version *version) {
    const char *cursor = text;

    memset(version, 0, sizeof(*version));
    if (*cursor == 'v') {
        cursor++;
    }

    for (size_t component = 0; component < 3; component++) {
        if (!parse_core_component(&cursor, &version->core[component])) {
            return 0;
        }
        if (component == 2) {
            break;
        }
        if (*cursor != '.') {
            return 0;
        }
        cursor++;
    }

    if (*cursor == '-') {
        const char *prerelease_start = ++cursor;
        while (*cursor != '\0' && *cursor != '+') {
            cursor++;
        }
        version->prerelease = prerelease_start;
        version->prerelease_length = (size_t)(cursor - prerelease_start);
        if (!validate_identifier_list(1, version->prerelease, version->prerelease_length)) {
            return 0;
        }
    }

    if (*cursor == '+') {
        const char *build_start = ++cursor;
        while (*cursor != '\0') {
            cursor++;
        }
        if (!validate_identifier_list(0, build_start, (size_t)(cursor - build_start))) {
            return 0;
        }
    }

    return *cursor == '\0';
}

static struct version_identifier next_version_identifier(const char **cursor, size_t *remaining) {
    struct version_identifier identifier = {
        .start = *cursor,
        .length = 0,
        .numeric = 1,
    };

    while (identifier.length < *remaining && (*cursor)[identifier.length] != '.') {
        if (!isdigit((unsigned char)(*cursor)[identifier.length])) {
            identifier.numeric = 0;
        }
        identifier.length++;
    }

    size_t consumed = identifier.length;
    if (consumed < *remaining) {
        consumed++;
    }
    *cursor += consumed;
    *remaining -= consumed;
    return identifier;
}

static int compare_version_identifiers(const struct version_identifier *candidate,
                                       const struct version_identifier *installed) {
    if (candidate->numeric != installed->numeric) {
        return candidate->numeric ? -1 : 1;
    }

    if (candidate->numeric && candidate->length != installed->length) {
        return candidate->length < installed->length ? -1 : 1;
    }

    size_t common_length =
        candidate->length < installed->length ? candidate->length : installed->length;
    int lexical = memcmp(candidate->start, installed->start, common_length);
    if (lexical != 0) {
        return lexical < 0 ? -1 : 1;
    }
    if (candidate->length == installed->length) {
        return 0;
    }

    return candidate->length < installed->length ? -1 : 1;
}

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
static int compare_prerelease_versions(const struct semantic_version *candidate,
                                       const struct semantic_version *installed) {
    if (candidate->prerelease_length == 0 || installed->prerelease_length == 0) {
        if (candidate->prerelease_length == installed->prerelease_length) {
            return 0;
        }
        return candidate->prerelease_length == 0 ? 1 : -1;
    }

    const char *candidate_cursor = candidate->prerelease;
    const char *installed_cursor = installed->prerelease;
    size_t candidate_remaining = candidate->prerelease_length;
    size_t installed_remaining = installed->prerelease_length;

    while (candidate_remaining > 0 && installed_remaining > 0) {
        struct version_identifier candidate_identifier =
            next_version_identifier(&candidate_cursor, &candidate_remaining);
        struct version_identifier installed_identifier =
            next_version_identifier(&installed_cursor, &installed_remaining);
        int comparison = compare_version_identifiers(&candidate_identifier, &installed_identifier);
        if (comparison != 0) {
            return comparison;
        }
    }

    if (candidate_remaining == installed_remaining) {
        return 0;
    }
    return candidate_remaining == 0 ? -1 : 1;
}

// Returns -1 when candidate is older, 0 when equal, 1 when newer, and -2 when invalid.
// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
static int compare_release_versions(const char *candidate_text, const char *installed_text) {
    struct semantic_version candidate;
    struct semantic_version installed;

    if (!parse_semantic_version(candidate_text, &candidate) ||
        !parse_semantic_version(installed_text, &installed)) {
        return -2;
    }

    for (size_t component = 0; component < 3; component++) {
        if (candidate.core[component] != installed.core[component]) {
            return candidate.core[component] < installed.core[component] ? -1 : 1;
        }
    }

    return compare_prerelease_versions(&candidate, &installed);
}

static void print_update_usage(void) {
    printf("Usage: agy update [options]\n\n"
           "Options:\n"
           "  -y, --yes, --auto  Apply updates without prompting\n"
           "  -h, --help         Show this help message\n\n"
           "Environment:\n"
           "  AGY_AUTO_UPDATE=1   Apply updates without prompting\n"
           "  AGY_UPDATE_DEBUG=1  Show startup update-check errors on stderr\n");
}

static int env_var_enabled(const char *name) {
    const char *value = getenv(name);

    return value != NULL && (strcmp(value, "1") == 0 || strcmp(value, "true") == 0);
}

static void report_update_check_error(enum update_check_mode mode, const char *message) {
    if (mode == UPDATE_CHECK_EXPLICIT) {
        printf("[agy-termux] Error: %s\n", message);
    } else if (env_var_enabled("AGY_UPDATE_DEBUG")) {
        (void)fprintf(stderr, "[agy-termux] Automatic update check failed: %s\n", message);
    }
}

static int extract_release_tag(const char *release_url, char *tag, size_t tag_size) {
    const size_t prefix_length = strlen(AGY_RELEASE_TAG_URL_PREFIX);
    const char *tag_start = NULL;
    size_t tag_length = 0;

    if (strncmp(release_url, AGY_RELEASE_TAG_URL_PREFIX, prefix_length) != 0) {
        return 0;
    }

    tag_start = release_url + prefix_length;
    tag_length = strlen(tag_start);
    if (tag_length == 0 || tag_length >= tag_size || !agy_is_valid_release_tag(tag_start)) {
        return 0;
    }

    memcpy(tag, tag_start, tag_length + 1);
    return 1;
}

static int fetch_latest_release_tag(enum update_check_mode mode, char *latest_tag,
                                    size_t latest_tag_size) {
    char command[768];
    char release_url[PATH_MAX] = {0};
    int written =
        snprintf(command, sizeof(command),
                 "command -v curl >/dev/null 2>&1 && "
                 "curl --proto '=https' --tlsv1.2 --connect-timeout 2 --max-time 5 -fLsL "
                 "-o /dev/null -w '%%{url_effective}\\n' -H 'User-Agent: Termux-Agy' '%s'",
                 AGY_LATEST_RELEASE_URL);
    if (written < 0 || written >= (int)sizeof(command)) {
        report_update_check_error(mode, "could not construct the release query");
        return 0;
    }

    // Intentionally uses the shell for a bounded curl request.
    // NOLINTNEXTLINE(bugprone-command-processor,cert-env33-c)
    FILE *pipe = popen(command, "r");
    if (pipe == NULL) {
        report_update_check_error(mode, "could not start the release query");
        return 0;
    }

    int received_line = fgets(release_url, sizeof(release_url), pipe) != NULL;
    int extra_output = received_line ? fgetc(pipe) : EOF;
    int command_status = pclose(pipe);

    if (command_status == -1 || !WIFEXITED(command_status) || WEXITSTATUS(command_status) != 0) {
        report_update_check_error(mode, "GitHub release query did not succeed");
        return 0;
    }
    if (!received_line || extra_output != EOF || strchr(release_url, '\n') == NULL) {
        report_update_check_error(mode, "GitHub returned an unexpected release response");
        return 0;
    }

    release_url[strcspn(release_url, "\r\n")] = '\0';
    if (!extract_release_tag(release_url, latest_tag, latest_tag_size)) {
        report_update_check_error(mode, "GitHub returned an unsupported release URL");
        return 0;
    }

    return 1;
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

// NOLINTNEXTLINE(bugprone-easily-swappable-parameters)
static int perform_transactional_update(const char *dir, const char *latest_tag) {
    char update_cmd[8192];
    int written = snprintf(
        update_cmd, sizeof(update_cmd),
        "install_dir=\"%s\"; release_tag=\"%s\"; "
        "tmp=$(mktemp -d \"${TMPDIR:-$install_dir/../tmp}/agy-update.XXXXXX\") "
        "|| exit 1; "
        "new_agy=\"$install_dir/.agy.new.$$\"; "
        "new_payload=\"$install_dir/.agy.va39.new.$$\"; "
        "old_agy=\"$install_dir/.agy.old.$$\"; "
        "old_payload=\"$install_dir/.agy.va39.old.$$\"; "
        "old_agy_part=\"$old_agy.part\"; old_payload_part=\"$old_payload.part\"; committed=0; "
        "cleanup() { status=$?; trap - EXIT HUP INT TERM; rollback_failed=0; "
        "if [ \"$committed\" -eq 0 ]; then "
        "[ ! -e \"$old_agy\" ] || mv -f \"$old_agy\" \"$install_dir/agy\" || "
        "rollback_failed=1; "
        "[ ! -e \"$old_payload\" ] || "
        "mv -f \"$old_payload\" \"$install_dir/agy.va39\" || rollback_failed=1; "
        "fi; "
        "rm -f \"$new_agy\" \"$new_payload\" \"$old_agy_part\" \"$old_payload_part\"; "
        "rm -rf \"$tmp\"; "
        "if [ \"$rollback_failed\" -ne 0 ]; then exit 125; fi; exit \"$status\"; }; "
        "trap cleanup EXIT; trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; "
        "curl -fsSL -o \"$tmp/antigravity-termux-standalone.tar.gz\" "
        "\"https://github.com/wallentx/antigravity-cli-termux/releases/download/"
        "$release_tag/antigravity-termux-standalone.tar.gz\" && "
        "tar -xzf \"$tmp/antigravity-termux-standalone.tar.gz\" -C \"$tmp\" "
        "agy agy.va39 && "
        "test -s \"$tmp/agy\" && test -x \"$tmp/agy\" && "
        "test -s \"$tmp/agy.va39\" && test -x \"$tmp/agy.va39\" && "
        "\"$tmp/agy\" --help >/dev/null 2>&1 && "
        "install -m 0755 \"$tmp/agy\" \"$new_agy\" && "
        "install -m 0755 \"$tmp/agy.va39\" \"$new_payload\" && "
        "cp -p \"$install_dir/agy\" \"$old_agy_part\" && "
        "mv -f \"$old_agy_part\" \"$old_agy\" && "
        "cp -p \"$install_dir/agy.va39\" \"$old_payload_part\" && "
        "mv -f \"$old_payload_part\" \"$old_payload\" && "
        "mv -f \"$new_payload\" \"$install_dir/agy.va39\" && "
        "mv -f \"$new_agy\" \"$install_dir/agy\" && "
        "committed=1 && { rm -f \"$old_agy\" \"$old_payload\" || :; }",
        dir, latest_tag);
    if (written < 0 || written >= (int)sizeof(update_cmd)) {
        return -1;
    }

    // Intentionally uses the shell for a staged, rollback-safe two-file replacement.
    // NOLINTNEXTLINE(bugprone-command-processor,cert-env33-c,cert-err34-c,cert-str02-c)
    return system(update_cmd);
}

// Query this fork's latest release and update the installed twin binaries in place.
static void check_and_perform_update(enum update_check_mode mode, const char *dir,
                                     int auto_update) {
    char latest_tag[64] = {0};
    if (mode == UPDATE_CHECK_EXPLICIT) {
        printf("[agy-termux] Querying latest release from wallentx/antigravity-cli-termux...\n");
    }
    if (!fetch_latest_release_tag(mode, latest_tag, sizeof(latest_tag))) {
        return;
    }

    const char *clean_latest = (latest_tag[0] == 'v') ? latest_tag + 1 : latest_tag;
    const char *clean_current =
        (AGY_TERMUX_VERSION[0] == 'v') ? &AGY_TERMUX_VERSION[1] : AGY_TERMUX_VERSION;
    int version_comparison = compare_release_versions(clean_latest, clean_current);

    if (mode == UPDATE_CHECK_EXPLICIT) {
        printf("[agy-termux] Current standalone version: v%s\n", clean_current);
        printf("[agy-termux] Latest available version : v%s\n", clean_latest);
    }

    if (version_comparison == -2) {
        report_update_check_error(mode, "could not compare installed and available versions");
        return;
    }
    if (version_comparison <= 0) {
        if (mode == UPDATE_CHECK_EXPLICIT) {
            if (version_comparison == 0) {
                printf("[agy-termux] You are already up to date with the latest standalone "
                       "release.\n");
            } else {
                printf("[agy-termux] Installed version v%s is newer than latest release v%s; "
                       "no update applied.\n",
                       clean_current, clean_latest);
            }
        }
        return;
    }

    printf("\n[agy-termux] A new update (v%s) is available!\n", clean_latest);
    if (!should_perform_update(auto_update)) {
        printf("[agy-termux] Update cancelled.\n");
        return;
    }

    printf("\n[agy-termux] Downloading and applying standalone update...\n");
    int status = perform_transactional_update(dir, latest_tag);
    if (status == 0) {
        if (mode == UPDATE_CHECK_STARTUP) {
            printf("[agy-termux] Update completed successfully. Starting the CLI...\n");
        } else {
            printf("[agy-termux] Update completed successfully! Please restart the CLI.\n");
        }
        return;
    }

    if (status != -1 && WIFEXITED(status) && WEXITSTATUS(status) == 125) {
        printf("[agy-termux] Error: Update failed and rollback could not be completed.\n");
    } else {
        printf("[agy-termux] Error: Update failed; installed binaries were left unchanged or "
               "restored.\n");
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
    return env_var_enabled("AGY_AUTO_UPDATE");
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

    check_and_perform_update(UPDATE_CHECK_EXPLICIT, dir, auto_update);
    return 0;
}

static int should_check_for_update_on_startup(int argc, char *const *argv) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        return 0;
    }

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0 ||
            strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--version") == 0) {
            return 0;
        }
    }

    return 1;
}

static void perform_startup_update_check(const char *dir, int argc, char **argv) {
    if (should_check_for_update_on_startup(argc, argv)) {
        check_and_perform_update(UPDATE_CHECK_STARTUP, dir, env_requests_auto_update());
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

static int require_resolver_config(const char *prefix) {
    char resolv_path[PATH_MAX];
    int written = snprintf(resolv_path, sizeof(resolv_path), "%s/etc/resolv.conf", prefix);
    if (written < 0 || written >= (int)sizeof(resolv_path)) {
        return 0;
    }

    if (access(resolv_path, R_OK) != 0) {
        (void)fprintf(stderr, "[agy-termux] Missing resolver configuration: %s\n", resolv_path);
        (void)fprintf(stderr, "[agy-termux] Install it with: pkg install resolv-conf\n");
        (void)fprintf(stderr,
                      "[agy-termux] Without this file, login and OAuth network requests may "
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

struct payload_launch {
    const char *runtime;
    const char *lib_path;
    const char *patched_bin;
    const char *qemu;
    int use_aether;
};

static int launch_payload(int argc, char **argv, const struct payload_launch *launch) {
    const char *exec_target = launch->runtime;
    const char *exec_error = "[agy-termux] execv failed";
    // Allocate enough space for QEMU, loader, library path, payload, arguments, and NULL.
    int new_argc = argc + 6;
    char **new_argv = malloc((size_t)new_argc * sizeof(*new_argv));
    if (!new_argv) {
        return 1;
    }

    int arg_idx = 0;
    if (launch->qemu) {
        new_argv[arg_idx++] = (char *)launch->qemu;
        exec_target = launch->qemu;
        exec_error = "[agy-termux] execv (qemu) failed";
    }
    new_argv[arg_idx++] = (char *)launch->runtime;
    if (launch->use_aether) {
        new_argv[arg_idx++] = "--";
    } else {
        new_argv[arg_idx++] = "--library-path";
        new_argv[arg_idx++] = (char *)launch->lib_path;
    }
    new_argv[arg_idx++] = (char *)launch->patched_bin;

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
    return 0;
}

int main(int argc, char **argv) {
    char exec_path[PATH_MAX];
    char lib_path[PATH_MAX + 16];
    char patched_bin[PATH_MAX];
    char dynamic_loader[PATH_MAX];
    char aether_runner[PATH_MAX];
    char cert_path[PATH_MAX];
    char prefix_path[PATH_MAX];
    char qemu_path[PATH_MAX];
    const char *prefix = getenv("PREFIX");
    const char *loader = NULL;
    const char *dir = NULL;
    const char *qemu = NULL;
    const char *exec_target = NULL;
    int written = 0;
    int use_aether = 0;
    ssize_t read_len = 0;

    if (!is_native_termux()) {
        print_non_termux_message();
        return 1;
    }

    if (!resolve_qemu_for_cpu(prefix, qemu_path, sizeof(qemu_path), &qemu)) {
        return 1;
    }
    written = snprintf(prefix_path, sizeof(prefix_path), "%s", prefix);
    if (written < 0 || written >= (int)sizeof(prefix_path)) {
        return 1;
    }
    written = snprintf(aether_runner, sizeof(aether_runner), "%s/bin/aether-run", prefix_path);
    // Keep the existing QEMU path on CPUs that cannot run the payload natively.
    use_aether = qemu == NULL && !env_var_enabled("AGY_NO_AETHER") && written >= 0 &&
                 written < (int)sizeof(aether_runner) && access(aether_runner, X_OK) == 0;
    written = snprintf(dynamic_loader, sizeof(dynamic_loader), "%s/glibc/lib/ld-linux-aarch64.so.1",
                       prefix_path);
    if (written < 0 || written >= (int)sizeof(dynamic_loader)) {
        return 1;
    }
    loader = dynamic_loader;
    exec_target = use_aether ? aether_runner : loader;

    if (!use_aether && access(loader, F_OK) != 0) {
        (void)fprintf(stderr, "[agy-termux] Missing Termux glibc loader: %s\n", loader);
        (void)fprintf(stderr,
                      "[agy-termux] You may need to install the glibc-repo and glibc packages.\n");
        return 1;
    }

    // Aether's Bionic wrapper needs the Termux execution shim. It replaces the
    // preload and library path itself before entering glibc, including children.
    if (!use_aether) {
        unsetenv("LD_PRELOAD");
        unsetenv("LD_LIBRARY_PATH");
    }

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

    if (is_update_command(argc, argv)) {
        if (update_command_requests_help(argc, argv)) {
            return handle_update_command(dir, argc, argv);
        }
        if (!require_resolver_config(prefix_path)) {
            return 1;
        }
        return handle_update_command(dir, argc, argv);
    }

    if (!require_resolver_config(prefix_path)) {
        return 1;
    }

    perform_startup_update_check(dir, argc, argv);

    // Use only the Termux glibc runtime libraries.
    written = snprintf(lib_path, sizeof(lib_path), "%s/glibc/lib", prefix_path);
    if (written < 0 || written >= (int)sizeof(lib_path)) {
        return 1;
    }

    // Construct path to the patched binary
    written = snprintf(patched_bin, sizeof(patched_bin), "%s/agy.va39", dir);
    if (written < 0 || written >= (int)sizeof(patched_bin)) {
        return 1;
    }

    const struct payload_launch launch = {
        .runtime = exec_target,
        .lib_path = lib_path,
        .patched_bin = patched_bin,
        .qemu = qemu,
        .use_aether = use_aether,
    };
    return launch_payload(argc, argv, &launch);
}
