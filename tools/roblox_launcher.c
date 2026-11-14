#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <mach-o/dyld.h>

int main(int argc, char *argv[]) {
    // Determine Mode: check environment variable or trigger file
    int mode_b = 0;
    if (getenv("NVMTL_NO_HALF_WORDS") != NULL || access("/tmp/NVMTL_NO_HALF_WORDS", F_OK) == 0) {
        mode_b = 1;
        setenv("NVMTL_NO_HALF_WORDS", "1", 1);
    } else {
        unsetenv("NVMTL_NO_HALF_WORDS");
    }

    setenv("DYLD_INSERT_LIBRARIES", "/Library/GPUBundles/libnvshim.dylib", 1);

    // Log launch info
    FILE *log = fopen("/tmp/roblox_launcher.log", "a");
    if (log) {
        time_t now = time(NULL);
        char tbuf[64];
        strftime(tbuf, sizeof(tbuf), "%Y-%m-%d %H:%M:%S", localtime(&now));
        fprintf(log, "[%s] RobloxLauncher pid=%d Mode=%s (NVMTL_NO_HALF_WORDS=%s)\n",
                tbuf, getpid(), mode_b ? "B (NO_HALF_WORDS=1)" : "A (Baseline, NO_HALF_WORDS unset)",
                mode_b ? "1" : "unset");
        fprintf(log, "    DYLD_INSERT_LIBRARIES=%s\n", getenv("DYLD_INSERT_LIBRARIES"));
        fprintf(log, "    argc=%d\n", argc);
        for (int i = 0; i < argc; ++i) {
            fprintf(log, "    argv[%d]=%s\n", i, argv[i]);
        }
        fclose(log);
    }

    char path[1024];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        strcpy(path, "/Applications/Roblox.app/Contents/MacOS/RobloxPlayer");
    }
    strcat(path, ".real");

    argv[0] = path;
    execv(path, argv);
    perror("execv failed");
    return 1;
}
