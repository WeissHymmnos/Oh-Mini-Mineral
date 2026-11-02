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

// ============================================================================
// Empirical malloc_trim Interception Hook
// ============================================================================
static volatile int g_malloc_trim_calls = 0;
static volatile size_t g_last_malloc_trim_pad = 0xDEADBEEF;

int malloc_trim(size_t pad) {
    g_malloc_trim_calls++;
    g_last_malloc_trim_pad = pad;
    static int (*real_malloc_trim)(size_t) = NULL;
    if (!real_malloc_trim) {
        real_malloc_trim = (int (*)(size_t))dlsym(RTLD_NEXT, "malloc_trim");
    }
    if (real_malloc_trim) {
        return real_malloc_trim(pad);
    }
    return 0;
}

// ============================================================================
// Process Introspection Helpers
// ============================================================================

static int count_open_fds(void) {
    int count = 0;
    DIR* dir = opendir("/proc/self/fd");
    if (!dir) return -1;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] != '.') {
            count++;
        }
    }
    closedir(dir);
    return count;
}

static int count_active_threads(void) {
    int count = 0;
    DIR* dir = opendir("/proc/self/task");
    if (!dir) return -1;
    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] != '.') {
            count++;
        }
    }
    closedir(dir);
    return count;
}

static size_t get_process_rss_bytes(void) {
    FILE* f = fopen("/proc/self/statm", "r");
    if (!f) return 0;
    unsigned long size = 0, resident = 0;
    if (fscanf(f, "%lu %lu", &size, &resident) != 2) {
        fclose(f);
        return 0;
    }
    fclose(f);
    long page_size = sysconf(_SC_PAGESIZE);
    return resident * (size_t)page_size;
}

static size_t get_heap_allocated_bytes(void) {
    struct mallinfo2 mi = mallinfo2();
    return (size_t)mi.uordblks;
}

static double get_elapsed_ms(struct timespec* start, struct timespec* end) {
    return (end->tv_sec - start->tv_sec) * 1000.0 + (end->tv_nsec - start->tv_nsec) / 1000000.0;
}

// Global test counters
static int g_test_count = 0;
static int g_pass_count = 0;
static int g_fail_count = 0;

static void report_check(bool cond, const char* name, const char* details) {
    g_test_count++;
    if (cond) {
        g_pass_count++;
        printf("  [PASS] %s", name);
        if (details && details[0]) printf(" (%s)", details);
        printf("\n");
    } else {
        g_fail_count++;
        printf("  [FAIL] %s", name);
        if (details && details[0]) printf(" (%s)", details);
        printf("\n");
    }
}

// ============================================================================
// SUITE 1: Protocol & malloc_trim(0) Interception Verification
// ============================================================================
static void test_suite_1_protocol_and_malloc_trim(void* dl_handle, const OmmPluginVTable* vtable) {
    printf("\n=== SUITE 1: Protocol Negotiation & malloc_trim(0) Interception ===\n");

    omm_plugin_get_vtable_fn get_vtable = (omm_plugin_get_vtable_fn)dlsym(dl_handle, "omm_plugin_get_vtable");
    report_check(get_vtable != NULL, "dlsym omm_plugin_get_vtable", "");
    report_check(get_vtable(0) == NULL, "Protocol version 0 rejected", "");
    report_check(get_vtable(0xFFFFFFFF) == NULL, "Protocol version 0xFFFFFFFF rejected", "");
    report_check(get_vtable(OMM_PLUGIN_PROTOCOL_VERSION) != NULL, "Protocol version 0x00010000 accepted", "");

    report_check(vtable->init != NULL && vtable->shutdown != NULL && vtable->get_status != NULL &&
                 vtable->suspend != NULL && vtable->resume != NULL && vtable->can_handle != NULL &&
                 vtable->open_stream != NULL && vtable->read_stream != NULL && vtable->seek_stream != NULL &&
                 vtable->close_stream != NULL && vtable->fetch_lyrics != NULL,
                 "All 11 VTable function pointers populated", "");

    int32_t rc = vtable->init("daemon.lua");
    report_check(rc == OMM_OK, "vtable->init('daemon.lua')", "");

    OmmPluginStatus status;
    rc = vtable->get_status(&status);
    report_check(rc == OMM_OK && status.state == OMM_PLUGIN_LAZY_WAKEUP, "Initial state == LAZY_WAKEUP (1)", "");

    // Open a stream to transition to ACTIVE
    OmmStreamHandle h = NULL;
    rc = vtable->open_stream("mineral://stream/test_init", &h);
    report_check(rc == OMM_OK && h != NULL, "open_stream transition to ACTIVE", "");
    rc = vtable->get_status(&status);
    report_check(status.state == OMM_PLUGIN_ACTIVE && status.active_streams == 1, "Status state == ACTIVE (2)", "");

    // Test suspend and malloc_trim interception
    int trim_calls_before = g_malloc_trim_calls;
    rc = vtable->suspend();
    report_check(rc == OMM_OK, "vtable->suspend() returned OMM_OK", "");
    rc = vtable->get_status(&status);
    report_check(status.state == OMM_PLUGIN_SUSPENDED, "Status state == SUSPENDED (3)", "");
    report_check(status.active_streams == 0, "Streams cleared on suspend", "");

    // Verify malloc_trim(0) was invoked
    int trim_calls_after = g_malloc_trim_calls;
    report_check(trim_calls_after > trim_calls_before, "malloc_trim was empirically intercepted", "");
    report_check(g_last_malloc_trim_pad == 0, "malloc_trim invoked with pad == 0", "");

    // Verify plugin RSS budget < 0.3 MB (< 307,200 bytes)
    char buf[64];
    snprintf(buf, sizeof(buf), "rss_bytes = %lu < 307200", (unsigned long)status.rss_bytes);
    report_check(status.rss_bytes < 307200, "Plugin reported RSS < 0.3 MB upon suspend", buf);

    // Test suspend idempotence
    int trim_before_idempotent = g_malloc_trim_calls;
    rc = vtable->suspend();
    report_check(rc == OMM_OK, "vtable->suspend() idempotent second call", "");
    // Suspend when already suspended is a no-op
    report_check(g_malloc_trim_calls == trim_before_idempotent, "Idempotent suspend does not re-trim unnecessarily", "");

    // Test resume
    rc = vtable->resume();
    report_check(rc == OMM_OK, "vtable->resume() returned OMM_OK", "");
    rc = vtable->get_status(&status);
    report_check(status.state == OMM_PLUGIN_LAZY_WAKEUP, "Status state returned to LAZY_WAKEUP (1)", "");
}

// ============================================================================
// SUITE 2: 50-Cycle Lifecycle & Memory Leak Verification
// ============================================================================
static void test_suite_2_50_cycles_memory_leak(const OmmPluginVTable* vtable) {
    printf("\n=== SUITE 2: 50 Repeated Cycles of Stream Wake -> Play -> Suspend -> Resume ===\n");

    const int TOTAL_CYCLES = 50;
    size_t rss_history[50];
    size_t heap_history[50];

    bool all_trim_invoked = true;
    bool all_budget_under_300k = true;
    bool all_transitions_clean = true;

    for (int i = 0; i < TOTAL_CYCLES; ++i) {
        int trim_before = g_malloc_trim_calls;

        // 1. Resume to Lazy Wakeup
        int32_t rc = vtable->resume();
        if (rc != OMM_OK) all_transitions_clean = false;

        // 2. Open stream (wake up Tokio runtime, active state)
        char uri[64];
        snprintf(uri, sizeof(uri), "mineral://stream/stress_cycle_%03d", i);
        OmmStreamHandle h = NULL;
        rc = vtable->open_stream(uri, &h);
        if (rc != OMM_OK || h == NULL) {
            all_transitions_clean = false;
        }

        // 3. Active Playback: read multiple blocks
        uint8_t audio_buf[4096];
        size_t total_read = 0;
        for (int b = 0; b < 4; ++b) {
            size_t bytes_read = 0;
            rc = vtable->read_stream(h, audio_buf, sizeof(audio_buf), &bytes_read);
            if (rc == OMM_OK) {
                total_read += bytes_read;
            }
        }
        if (total_read == 0) all_transitions_clean = false;

        // 4. In-window and out-of-window seek
        int64_t out_pos = 0;
        rc = vtable->seek_stream(h, 4096, 0 /* SEEK_SET */, &out_pos);
        if (rc != OMM_OK || out_pos != 4096) all_transitions_clean = false;

        rc = vtable->seek_stream(h, 1024 * 1024, 0 /* SEEK_SET */, &out_pos);
        if (rc != OMM_OK || out_pos != 1024 * 1024) all_transitions_clean = false;

        // 5. Close stream
        rc = vtable->close_stream(h);
        if (rc != OMM_OK) all_transitions_clean = false;

        // 6. Shallow Suspend
        rc = vtable->suspend();
        if (rc != OMM_OK) all_transitions_clean = false;

        // Check trim call
        if (g_malloc_trim_calls <= trim_before || g_last_malloc_trim_pad != 0) {
            all_trim_invoked = false;
        }

        // Check plugin status
        OmmPluginStatus status;
        rc = vtable->get_status(&status);
        if (rc != OMM_OK || status.state != OMM_PLUGIN_SUSPENDED || status.active_streams != 0) {
            all_transitions_clean = false;
        }
        if (status.rss_bytes >= 307200) {
            all_budget_under_300k = false;
        }

        // Measure OS process RSS & heap
        rss_history[i] = get_process_rss_bytes();
        heap_history[i] = get_heap_allocated_bytes();

        if ((i + 1) % 10 == 0 || i == 0) {
            printf("  Cycle %2d/50: Status RSS=%lu B, OS RSS=%zu KB, Heap=%zu KB, TrimCalls=%d\n",
                   i + 1, (unsigned long)status.rss_bytes, rss_history[i] / 1024,
                   heap_history[i] / 1024, g_malloc_trim_calls);
        }
    }

    report_check(all_transitions_clean, "50 cycles stream wake -> play -> suspend -> resume succeeded", "");
    report_check(all_trim_invoked, "malloc_trim(0) invoked in all 50 cycles upon suspend", "");
    report_check(all_budget_under_300k, "Plugin reported RSS < 0.3 MB (< 307,200 B) in all 50 cycles", "");

    // Monotonic Memory Leak Analysis:
    // We compare cycle 5 (after initial dynamic linker, glibc arena, and Tokio thread-pool warmups)
    // to cycle 49 (final cycle).
    size_t rss_baseline = rss_history[4];   // cycle 5
    size_t rss_final = rss_history[49];     // cycle 50
    ssize_t delta_rss_bytes = (ssize_t)rss_final - (ssize_t)rss_baseline;
    ssize_t delta_rss_kb = delta_rss_bytes / 1024;

    size_t heap_baseline = heap_history[4];
    size_t heap_final = heap_history[49];
    ssize_t delta_heap_bytes = (ssize_t)heap_final - (ssize_t)heap_baseline;

    char leak_buf[128];
    snprintf(leak_buf, sizeof(leak_buf), "Delta RSS = %ld KB (baseline=%zu KB, final=%zu KB, limit <= 64 KB)",
             (long)delta_rss_kb, rss_baseline / 1024, rss_final / 1024);
    report_check(delta_rss_kb <= 64, "Zero monotonic memory leak across 50 cycles (Delta RSS <= 64 KB)", leak_buf);

    char heap_buf[128];
    snprintf(heap_buf, sizeof(heap_buf), "Delta Heap = %ld B (baseline=%zu B, final=%zu B)",
             (long)delta_heap_bytes, heap_baseline, heap_final);
    report_check(delta_heap_bytes <= 65536, "Glibc heap growth <= 64 KB across 50 cycles", heap_buf);
}

// ============================================================================
// SUITE 3: 50-Cycle Deep Unload (dlopen / dlclose) Safety
// ============================================================================
static void test_suite_3_50_cycles_deep_unload(const char* lib_path) {
    printf("\n=== SUITE 3: 50 Cycles of Deep Unload (dlopen -> init -> stream -> suspend -> dlclose) ===\n");

    int initial_fds = count_open_fds();
    int initial_threads = count_active_threads();
    printf("  Initial baseline: Open FDs = %d, Active Threads = %d\n", initial_fds, initial_threads);

    bool all_dl_success = true;
    bool fd_leak_detected = false;
    bool thread_leak_detected = false;

    const int DL_CYCLES = 50;

    for (int i = 0; i < DL_CYCLES; ++i) {
        void* h = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            all_dl_success = false;
            printf("  [FAIL] dlopen failed at cycle %d: %s\n", i + 1, dlerror());
            break;
        }

        omm_plugin_get_vtable_fn get_vtable = (omm_plugin_get_vtable_fn)dlsym(h, "omm_plugin_get_vtable");
        if (!get_vtable) {
            all_dl_success = false;
            dlclose(h);
            break;
        }

        const OmmPluginVTable* vt = get_vtable(OMM_PLUGIN_PROTOCOL_VERSION);
        if (!vt) {
            all_dl_success = false;
            dlclose(h);
            break;
        }

        // Init
        vt->init("daemon.lua");

        // Open synthetic stream
        OmmStreamHandle sh = NULL;
        if (vt->open_stream("mineral://stream/dlopen_cycle", &sh) == OMM_OK && sh != NULL) {
            uint8_t buf[2048];
            size_t out_r = 0;
            vt->read_stream(sh, buf, sizeof(buf), &out_r);
            vt->close_stream(sh);
        }

        // Shallow suspend
        vt->suspend();

        // Deep unload: dlclose
        dlclose(h);

        // Small yield to let OS finish thread cleanup
        usleep(5000); // 5ms

        int cur_fds = count_open_fds();
        int cur_threads = count_active_threads();

        if (cur_fds > initial_fds + 1) { // allow 1 temporary dir fd jitter
            fd_leak_detected = true;
        }
        if (cur_threads > initial_threads) {
            thread_leak_detected = true;
        }

        if ((i + 1) % 10 == 0 || i == 0) {
            printf("  Cycle %2d/50: dlopen -> stream -> suspend -> dlclose OK. FDs=%d, Threads=%d\n",
                   i + 1, cur_fds, cur_threads);
        }
    }

    report_check(all_dl_success, "50 cycles of dlopen/dlclose executed cleanly", "");

    int final_fds = count_open_fds();
    int final_threads = count_active_threads();
    char fd_buf[64], th_buf[64];
    snprintf(fd_buf, sizeof(fd_buf), "initial=%d, final=%d", initial_fds, final_fds);
    snprintf(th_buf, sizeof(th_buf), "initial=%d, final=%d", initial_threads, final_threads);

    report_check(!fd_leak_detected && final_fds <= initial_fds, "Zero file descriptor leak across 50 dlopen/dlclose cycles", fd_buf);
    report_check(!thread_leak_detected && final_threads <= initial_threads, "Zero orphaned threads across 50 dlopen/dlclose cycles", th_buf);
}

// ============================================================================
// SUITE 4: Re-entrancy, Rapid Races & Concurrency Stress
// ============================================================================

typedef struct {
    const OmmPluginVTable* vtable;
    int iterations;
    int worker_id;
    bool success;
} WorkerArgs;

static void* concurrent_stream_worker(void* arg) {
    WorkerArgs* w = (WorkerArgs*)arg;
    w->success = true;

    for (int i = 0; i < w->iterations; ++i) {
        char uri[64];
        snprintf(uri, sizeof(uri), "mineral://stream/worker_%d_%d", w->worker_id, i);
        OmmStreamHandle h = NULL;
        int32_t rc = w->vtable->open_stream(uri, &h);
        if (rc != OMM_OK || h == NULL) {
            w->success = false;
            break;
        }

        uint8_t buf[1024];
        size_t out_r = 0;
        rc = w->vtable->read_stream(h, buf, sizeof(buf), &out_r);
        if (rc != OMM_OK && rc != OMM_ERR_SUSPENDED) {
            w->success = false;
            break;
        }

        w->vtable->close_stream(h);
    }
    return NULL;
}

static void* blocking_read_worker(void* arg) {
    WorkerArgs* w = (WorkerArgs*)arg;
    w->success = true;

    OmmStreamHandle h = NULL;
    int32_t rc = w->vtable->open_stream("mineral://stream/timeout_simulation", &h);
    if (rc != OMM_OK || h == NULL) {
        w->success = false;
        return NULL;
    }

    uint8_t buf[512];
    size_t out_r = 0;
    // This read will block for 200ms unless cancelled or timed out
    rc = w->vtable->read_stream(h, buf, sizeof(buf), &out_r);
    // Expect either OMM_ERR_STREAM_TIMEOUT or OMM_ERR_SUSPENDED
    if (rc != OMM_ERR_STREAM_TIMEOUT && rc != OMM_ERR_SUSPENDED && rc != OMM_ERR_INVALID_PARAM) {
        w->success = false;
    }

    w->vtable->close_stream(h);
    return NULL;
}

static void test_suite_4_races_and_concurrency(const OmmPluginVTable* vtable) {
    printf("\n=== SUITE 4: Re-entrancy, Rapid Races & Concurrency Stress ===\n");

    // 4.1 Rapid suspend/resume toggling (100 times)
    bool rapid_toggle_ok = true;
    for (int i = 0; i < 100; ++i) {
        if (vtable->suspend() != OMM_OK) rapid_toggle_ok = false;
        if (vtable->resume() != OMM_OK) rapid_toggle_ok = false;
    }
    report_check(rapid_toggle_ok, "100 rapid suspend/resume toggles without crash or stall", "");

    // 4.2 Concurrent open/read/close across 4 threads
    const int NUM_THREADS = 4;
    pthread_t threads[4];
    WorkerArgs args[4];

    // Ensure plugin is initialized & resumed
    vtable->resume();

    for (int t = 0; t < NUM_THREADS; ++t) {
        args[t].vtable = vtable;
        args[t].iterations = 25;
        args[t].worker_id = t;
        args[t].success = false;
        pthread_create(&threads[t], NULL, concurrent_stream_worker, &args[t]);
    }

    bool all_workers_ok = true;
    for (int t = 0; t < NUM_THREADS; ++t) {
        pthread_join(threads[t], NULL);
        if (!args[t].success) all_workers_ok = false;
    }
    report_check(all_workers_ok, "4 concurrent threads x 25 stream sessions (100 streams total) passed", "");

    // 4.3 Concurrent blocking read vs suspend
    pthread_t reader_thread;
    WorkerArgs reader_arg = { vtable, 1, 99, false };
    pthread_create(&reader_thread, NULL, blocking_read_worker, &reader_arg);

    // Sleep 50ms so reader is inside read_stream / waiting
    usleep(50000);

    // Call suspend while read is in progress
    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);
    int32_t susp_rc = vtable->suspend();
    clock_gettime(CLOCK_MONOTONIC, &t_end);
    double susp_elapsed = get_elapsed_ms(&t_start, &t_end);

    pthread_join(reader_thread, NULL);

    char race_buf[64];
    snprintf(race_buf, sizeof(race_buf), "suspend took %.2f ms, worker status=%d", susp_elapsed, reader_arg.success);
    report_check(susp_rc == OMM_OK && reader_arg.success, "Concurrent 200ms blocking read vs suspend resolved safely", race_buf);

    // Resume for next suite
    vtable->resume();
}

// ============================================================================
// SUITE 5: Adversarial Boundary & Fuzzing Inputs
// ============================================================================
static void test_suite_5_adversarial_boundary_inputs(const OmmPluginVTable* vtable) {
    printf("\n=== SUITE 5: Adversarial Boundary Inputs & Fuzzing ===\n");

    // 5.1 Invalid URIs
    report_check(vtable->can_handle(NULL) == 0, "can_handle(NULL) returns 0", "");
    report_check(vtable->can_handle("") == 0, "can_handle('') returns 0", "");
    report_check(vtable->can_handle("ftp://files.example.com/audio.mp3") == 0, "can_handle ftp scheme returns 0", "");
    report_check(vtable->can_handle("file:///music/song.flac") == 0, "can_handle local file scheme returns 0", "");

    OmmStreamHandle h = NULL;
    report_check(vtable->open_stream(NULL, &h) == OMM_ERR_INVALID_PARAM, "open_stream(NULL) returns OMM_ERR_INVALID_PARAM", "");
    report_check(vtable->open_stream("mineral://stream/test", NULL) == OMM_ERR_INVALID_PARAM, "open_stream with NULL out_handle returns OMM_ERR_INVALID_PARAM", "");
    report_check(vtable->open_stream("file:///local.mp3", &h) == OMM_ERR_UNSUPPORTED_URI, "open_stream on file:// returns OMM_ERR_UNSUPPORTED_URI", "");

    // Giant URI (65KB)
    char* giant_uri = (char*)malloc(65536);
    memset(giant_uri, 'A', 65535);
    giant_uri[65535] = '\0';
    memcpy(giant_uri, "mineral://", 10);
    report_check(vtable->open_stream(giant_uri, &h) == OMM_OK, "open_stream handles 65KB URI without panic/buffer overflow", "");
    if (h) vtable->close_stream(h);
    free(giant_uri);

    // Invalid UTF-8 sequence URI
    char invalid_utf8[] = { 'm', 'i', 'n', 'e', 'r', 'a', 'l', ':', '/', '/', (char)0xFF, (char)0xFE, '\0' };
    report_check(vtable->open_stream(invalid_utf8, &h) == OMM_ERR_INVALID_PARAM, "Invalid UTF-8 URI safely returns OMM_ERR_INVALID_PARAM", "");

    // 5.2 Invalid Stream Handles
    uint8_t read_buf[128];
    size_t out_read = 0;
    int64_t out_pos = 0;
    report_check(vtable->read_stream(NULL, read_buf, sizeof(read_buf), &out_read) == OMM_ERR_INVALID_PARAM, "read_stream(NULL handle) returns INVALID_PARAM", "");
    report_check(vtable->read_stream((OmmStreamHandle)(uintptr_t)0xDEADBEEF, read_buf, sizeof(read_buf), &out_read) == OMM_ERR_INVALID_PARAM, "read_stream(dangling handle) returns INVALID_PARAM", "");
    report_check(vtable->seek_stream(NULL, 0, 0, &out_pos) == OMM_ERR_INVALID_PARAM, "seek_stream(NULL handle) returns INVALID_PARAM", "");
    report_check(vtable->close_stream(NULL) == OMM_ERR_INVALID_PARAM, "close_stream(NULL handle) returns INVALID_PARAM", "");
    report_check(vtable->close_stream((OmmStreamHandle)(uintptr_t)999999) == OMM_ERR_INVALID_PARAM, "close_stream(invalid handle) returns INVALID_PARAM", "");

    // 5.3 Operations while suspended
    h = NULL;
    vtable->open_stream("mineral://stream/test_suspend_ops", &h);
    assert(h != NULL);
    vtable->suspend();

    // Calling read_stream while suspended
    report_check(vtable->read_stream(h, read_buf, sizeof(read_buf), &out_read) == OMM_ERR_SUSPENDED, "read_stream on handle while SUSPENDED returns OMM_ERR_SUSPENDED (-8)", "");
    report_check(vtable->seek_stream(h, 0, 0, &out_pos) == OMM_ERR_SUSPENDED, "seek_stream on handle while SUSPENDED returns OMM_ERR_SUSPENDED (-8)", "");

    // Resume and close
    vtable->resume();
    vtable->close_stream(h);

    // 5.4 Lyrics caller-allocated buffer fuzzing
    size_t lyrics_len = 0;
    report_check(vtable->fetch_lyrics(NULL, NULL, 0, &lyrics_len) == OMM_ERR_INVALID_PARAM, "fetch_lyrics(NULL URI) returns INVALID_PARAM", "");
    report_check(vtable->fetch_lyrics("mineral://stream/test", NULL, 0, &lyrics_len) == OMM_ERR_BUFFER_TOO_SMALL && lyrics_len > 0, "fetch_lyrics size probe with NULL buf returns BUFFER_TOO_SMALL and required len", "");

    char tiny_buf[4];
    report_check(vtable->fetch_lyrics("mineral://stream/test", tiny_buf, sizeof(tiny_buf), &lyrics_len) == OMM_ERR_BUFFER_TOO_SMALL, "fetch_lyrics undersized buffer returns BUFFER_TOO_SMALL", "");

    char valid_buf[2048];
    memset(valid_buf, 0xCC, sizeof(valid_buf));
    report_check(vtable->fetch_lyrics("mineral://stream/test", valid_buf, sizeof(valid_buf), &lyrics_len) == OMM_OK, "fetch_lyrics adequate buffer returns OMM_OK", "");
    report_check(valid_buf[lyrics_len] == '\0', "fetch_lyrics guarantees null-terminated string", "");
    report_check(strstr(valid_buf, "[00:") != NULL, "fetch_lyrics output matches valid synchronized LRC timestamp format", "");
}

// ============================================================================
// MAIN RUNNER
// ============================================================================
int main(void) {
    printf("===============================================================================\n");
    printf("  LIBOMM_MINERAL EMPIRICAL LIFECYCLE & MEMORY STRESS VERIFICATION HARNESS     \n");
    printf("===============================================================================\n");

    const char* lib_path = "./bin/libomm_mineral.so";
    if (access(lib_path, R_OK) != 0) {
        lib_path = "./target/release/libomm_mineral.so";
    }

    void* dl_handle = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
    if (!dl_handle) {
        fprintf(stderr, "[FATAL] Failed to dlopen %s: %s\n", lib_path, dlerror());
        return 1;
    }

    omm_plugin_get_vtable_fn get_vtable = (omm_plugin_get_vtable_fn)dlsym(dl_handle, "omm_plugin_get_vtable");
    if (!get_vtable) {
        fprintf(stderr, "[FATAL] Symbol omm_plugin_get_vtable not found: %s\n", dlerror());
        dlclose(dl_handle);
        return 1;
    }

    const OmmPluginVTable* vtable = get_vtable(OMM_PLUGIN_PROTOCOL_VERSION);
    if (!vtable) {
        fprintf(stderr, "[FATAL] Failed to negotiate VTable protocol version 0x%08X\n", OMM_PLUGIN_PROTOCOL_VERSION);
        dlclose(dl_handle);
        return 1;
    }

    // Run test suites
    test_suite_1_protocol_and_malloc_trim(dl_handle, vtable);
    test_suite_2_50_cycles_memory_leak(vtable);

    // Shutdown and dlclose initial handle before Suite 3
    vtable->shutdown();
    dlclose(dl_handle);

    // Run deep unload suite (repeated dlopen/dlclose)
    test_suite_3_50_cycles_deep_unload(lib_path);

    // Reload for Suites 4 & 5
    dl_handle = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
    assert(dl_handle != NULL);
    get_vtable = (omm_plugin_get_vtable_fn)dlsym(dl_handle, "omm_plugin_get_vtable");
    vtable = get_vtable(OMM_PLUGIN_PROTOCOL_VERSION);
    vtable->init("daemon.lua");

    test_suite_4_races_and_concurrency(vtable);
    test_suite_5_adversarial_boundary_inputs(vtable);

    vtable->shutdown();
    dlclose(dl_handle);

    printf("\n===============================================================================\n");
    printf("STRESS TEST SUMMARY:\n");
    printf("  Total Checks : %d\n", g_test_count);
    printf("  Passed       : %d\n", g_pass_count);
    printf("  Failed       : %d\n", g_fail_count);
    printf("===============================================================================\n");

    if (g_fail_count == 0) {
        printf(">>> VERDICT: ALL LIFECYCLE & MEMORY STRESS TESTS PASSED (CONFIRM) <<<\n");
        return 0;
    } else {
        printf(">>> VERDICT: STRESS FAILURES DETECTED (REJECT) <<<\n");
        return 1;
    }
}
