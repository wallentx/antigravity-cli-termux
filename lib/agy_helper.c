#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>

int main(int argc, char** argv) {
    // 1. Clear conflicting Android Bionic preloads and search paths
    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");

    // 2. Set dynamic Go resolver and SSL configurations
    setenv("GODEBUG", "netdns=cgo", 1);
    setenv("SSL_CERT_FILE", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);

    // 3. Resolve the helper's own absolute directory dynamically at runtime
    char exec_path[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
    if (len == -1) {
        return 1;
    }
    exec_path[len] = '\0';

    // Get the directory containing the executable
    char* dir = dirname(exec_path);

    // 4. Construct relocatable paths relative to our executable's location
    char lib_path[PATH_MAX * 2];
    char patched_bin[PATH_MAX];
    char* loader = "/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1";

    // lib_path: <exec_dir>/../lib:/data/data/com.termux/files/usr/glibc/lib
    snprintf(lib_path, sizeof(lib_path), "%s/../lib:/data/data/com.termux/files/usr/glibc/lib", dir);
    
    // patched_bin: <exec_dir>/agy.va39
    snprintf(patched_bin, sizeof(patched_bin), "%s/agy.va39", dir);

    // 5. Construct argument array
    char** new_argv = malloc((argc + 4) * sizeof(char*));
    if (!new_argv) {
        return 1;
    }

    new_argv[0] = loader;
    new_argv[1] = "--library-path";
    new_argv[2] = lib_path;
    new_argv[3] = patched_bin;

    for (int i = 1; i < argc; i++) {
        new_argv[i + 3] = argv[i];
    }
    new_argv[argc + 3] = NULL;

    // 6. Execute the glibc loader
    execv(loader, new_argv);

    free(new_argv);
    return 1;
}
