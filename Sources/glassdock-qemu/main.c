// SPDX-License-Identifier: Apache-2.0
// One QEMU library per process: QEMU does not support reinitialization.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: glassdock-qemu library arguments...\n"); return 2; }
    void *library = dlopen(argv[1], RTLD_LOCAL | RTLD_LAZY | RTLD_FIRST);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    int (*tool)(int, char **) = dlsym(library, "main");
    if (tool) return tool(argc - 1, argv + 1);
    int (*tpm)(int, char **, const char *, const char *) = dlsym(library, "swtpm_main");
    if (tpm) return tpm(argc - 1, argv + 1, "swtpm", "socket");
    void (*initialize)(int, char **, char **) = dlsym(library, "qemu_init");
    void (*loop)(void) = dlsym(library, "qemu_main_loop");
    void (*cleanup)(void) = dlsym(library, "qemu_cleanup");
    if (!initialize || !loop || !cleanup) { fprintf(stderr, "Unsupported QEMU library ABI\n"); return 1; }
    initialize(argc - 1, argv + 1, environ);
    loop();
    cleanup();
    return 0;
}
