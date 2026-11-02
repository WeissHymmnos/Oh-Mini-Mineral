#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <assert.h>
#include <dlfcn.h>
#include <dirent.h>
#include <pthread.h>
#include <time.h>
#include <malloc.h>
#include <sys/time.h>
#include "omm_abi.h"

static volatile int g_trim_calls = 0;
static volatile size_t g_last_pad = 0xDEADBEEF;

int malloc_trim(size_t pad) {
    g_trim_calls++;
    g_last_pad = pad;
    static int (*real_trim)(size_t) = NULL;
    if (!real_trim) {
        real_trim = (int (*)(size_t))dlsym(RTLD_NEXT, "malloc_trim");
    }
    if (real_trim) return real_trim(pad);
    return 0;
}

static int count_fds(void) {
    int count = 0;
    DIR* dir = opendir("/proc/self/fd");
    if (!dir) return -1;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] != '.') count++;
    }
    closedir(dir);
    return count;
}

static int count_threads(void) {
    int count = 0;
    DIR* dir = opendir("/proc/self/task");
    if (!dir) return -1;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] != '.') count++;
    }
    closedir(dir);
    return count;
}

static size_t get_rss(void) {
    FILE* f = fopen("/proc/self/statm", "r");
    if (!f) return 0;
    unsigned long size = 0, resident = 0;
    if (fscanf(f, "%lu %lu", &size, &resident) != 2) {
        fclose(f);
        return 0;
    }
    fclose(f);
    return resident * (size_t)sysconf(_SC_PAGESIZE);
}

int main(void) {
    printf("====================================================================\n");
    printf("  ADVERSARIAL STRESS CHALLENGER: LIFECYCLE & MEMORY DEEP VERIFICATION\n");
    printf("====================================================================\n");

    const char* lib_path = "./bin/libomm_mineral.so";
    if (access(lib_path, R_OK) != 0) {
        lib_path = "./target/release/libomm_mineral.so";
    }

    void* h = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    omm_plugin_get_vtable_fn get_vtable = (omm_plugin_get_vtable_fn)dlsym(h, "omm_plugin_get_vtable");
    assert(get_vtable != NULL);
    const OmmPluginVTable* vt = get_vtable(OMM_PLUGIN_PROTOCOL_VERSION);
    assert(vt != NULL);

    int rc = vt->init("daemon.lua");
    assert(rc == OMM_OK);

    // -------------------------------------------------------------------------
    // TEST 1: 100 Continuous Cycles of Stream Wake -> Play -> Suspend -> Resume
    // -------------------------------------------------------------------------
    printf("\n[CHALLENGE 1] Executing 100 extended cycles of Stream Wake -> Play -> Suspend...\n");
    const int CYCLES = 100;
    size_t rss_history[100];
    bool trim_invoked_all = true;
    bool under_300k_all = true;

    for (int i = 0; i < CYCLES; ++i) {
        int trim_before = g_trim_calls;
        assert(vt->resume() == OMM_OK);

        char uri[64];
        snprintf(uri, sizeof(uri), "mineral://stream/adv_%03d", i);
        OmmStreamHandle sh = NULL;
        assert(vt->open_stream(uri, &sh) == OMM_OK);
        assert(sh != NULL);

        uint8_t buf[8192];
        size_t out_r = 0;
        for (int b = 0; b < 8; ++b) {
            vt->read_stream(sh, buf, sizeof(buf), &out_r);
        }

        assert(vt->close_stream(sh) == OMM_OK);
        assert(vt->suspend() == OMM_OK);

        if (g_trim_calls <= trim_before || g_last_pad != 0) {
            trim_invoked_all = false;
        }

        OmmPluginStatus status;
        assert(vt->get_status(&status) == OMM_OK);
        if (status.rss_bytes >= 307200) {
            under_300k_all = false;
        }

        rss_history[i] = get_rss();
        if ((i + 1) % 25 == 0 || i == 0) {
            printf("  Cycle %3d/100: Status RSS=%lu B, OS RSS=%zu KB, TrimCalls=%d\n",
                   i + 1, (unsigned long)status.rss_bytes, rss_history[i] / 1024, g_trim_calls);
        }
    }

    printf("  [PASS] malloc_trim(0) invoked in 100/100 cycles: %s\n", trim_invoked_all ? "YES" : "NO");
    printf("  [PASS] Status RSS < 307200 in 100/100 cycles: %s\n", under_300k_all ? "YES" : "NO");

    size_t rss_base = rss_history[4];
    size_t rss_end = rss_history[99];
    ssize_t delta_rss_kb = ((ssize_t)rss_end - (ssize_t)rss_base) / 1024;
    printf("  -> Delta RSS across 100 cycles (cycle 5 to 100): %ld KB (baseline=%zu KB, final=%zu KB)\n",
           (long)delta_rss_kb, rss_base / 1024, rss_end / 1024);

    assert(trim_invoked_all);
    assert(under_300k_all);
    assert(delta_rss_kb <= 64);

    vt->shutdown();
    dlclose(h);

    // -------------------------------------------------------------------------
    // TEST 2: 100 Cycles of Rapid Deep Unload (dlopen -> init -> stream -> suspend -> dlclose)
    // Testing with zero delay between dlclose and dlopen
    // -------------------------------------------------------------------------
    printf("\n[CHALLENGE 2] Executing 100 cycles of Rapid Deep Unload (zero delay)...\n");
    int base_fds = count_fds();
    int base_threads = count_threads();
    printf("  Baseline: FDs=%d, Threads=%d\n", base_fds, base_threads);

    bool deep_unload_ok = true;
    for (int i = 0; i < 100; ++i) {
        void* lib = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
        if (!lib) {
            fprintf(stderr, "Cycle %d dlopen failed: %s\n", i + 1, dlerror());
            deep_unload_ok = false;
            break;
        }

        omm_plugin_get_vtable_fn gv = (omm_plugin_get_vtable_fn)dlsym(lib, "omm_plugin_get_vtable");
        if (!gv) {
            fprintf(stderr, "Cycle %d dlsym failed: %s\n", i + 1, dlerror());
            dlclose(lib);
            deep_unload_ok = false;
            break;
        }

        const OmmPluginVTable* v = gv(OMM_PLUGIN_PROTOCOL_VERSION);
        if (!v) {
            dlclose(lib);
            deep_unload_ok = false;
            break;
        }

        v->init("daemon.lua");
        OmmStreamHandle s = NULL;
        if (v->open_stream("mineral://stream/deep_test", &s) == OMM_OK && s) {
            uint8_t b[1024];
            size_t r = 0;
            v->read_stream(s, b, sizeof(b), &r);
            v->close_stream(s);
        }

        v->suspend();
        dlclose(lib);

        // Immediate next cycle (0 delay)
        if ((i + 1) % 25 == 0 || i == 0) {
            printf("  Cycle %3d/100 deep unload OK. FDs=%d, Threads=%d\n",
                   i + 1, count_fds(), count_threads());
        }
    }

    int final_fds = count_fds();
    int final_threads = count_threads();
    printf("  Final metrics: FDs=%d (delta=%d), Threads=%d (delta=%d)\n",
           final_fds, final_fds - base_fds, final_threads, final_threads - base_threads);

    assert(deep_unload_ok);
    assert(final_fds <= base_fds);
    assert(final_threads <= base_threads);

    printf("\n>>> ALL ADVERSARIAL STRESS CHALLENGES CONFIRMED SUCCESSFULLY! <<<\n");
    return 0;
}
