#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <assert.h>
#include <sys/time.h>

#include "omm_abi.h"

static int g_tests_run = 0;
static int g_tests_passed = 0;
static int g_tests_failed = 0;

#define TEST_ASSERT(cond, msg) do { \
    g_tests_run++; \
    if (cond) { \
        g_tests_passed++; \
        printf("  [PASS] %s\n", msg); \
    } else { \
        g_tests_failed++; \
        printf("  [FAIL] %s (Line %d)\n", msg, __LINE__); \
    } \
} while (0)

static uint64_t get_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
}

// ----------------------------------------------------------------------------
// Thread Worker for Concurrent Read vs Close Race
// ----------------------------------------------------------------------------
typedef struct {
    const OmmPluginVTable* vtable;
    OmmStreamHandle handle;
    volatile bool stop;
    int read_count;
    int timeout_count;
    int eof_count;
    int err_count;
} read_worker_arg_t;

static void* read_stream_worker(void* arg) {
    read_worker_arg_t* w = (read_worker_arg_t*)arg;
    uint8_t buf[4096];
    size_t bytes_read = 0;

    while (!w->stop) {
        int32_t rc = w->vtable->read_stream(w->handle, buf, sizeof(buf), &bytes_read);
        if (rc == OMM_OK) {
            w->read_count++;
            if (bytes_read == 0) {
                w->eof_count++;
                break;
            }
        } else if (rc == OMM_ERR_STREAM_TIMEOUT) {
            w->timeout_count++;
        } else if (rc == OMM_ERR_STREAM_EOF || rc == OMM_ERR_INVALID_PARAM || rc == OMM_ERR_SUSPENDED) {
            w->eof_count++;
            break;
        } else {
            w->err_count++;
            break;
        }
        usleep(100);
    }
    return NULL;
}

int main(void) {
    printf("======================================================================\n");
    printf("   Oh-My-Mineral: C-ABI & Mineral Plugin Adversarial Hardening Suite  \n");
    printf("======================================================================\n");

    void* lib = dlopen("bin/libomm_mineral.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        lib = dlopen("target/release/libomm_mineral.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (!lib) {
        fprintf(stderr, "Fatal: Could not dlopen libomm_mineral.so: %s\n", dlerror());
        return 1;
    }

    typedef const OmmPluginVTable* (*get_vtable_fn)(uint32_t);
    get_vtable_fn get_vtable = (get_vtable_fn)dlsym(lib, "omm_plugin_get_vtable");
    TEST_ASSERT(get_vtable != NULL, "dlsym(omm_plugin_get_vtable) succeeded");
    if (!get_vtable) return 1;

    // 1. Protocol Version Negotiation Edge Cases
    printf("\n--- Test Suite 1: Protocol Version Negotiation ---\n");
    const OmmPluginVTable* vt_bad0 = get_vtable(0);
    TEST_ASSERT(vt_bad0 == NULL, "Protocol version 0 returns NULL");

    const OmmPluginVTable* vt_bad1 = get_vtable(0x00010001);
    TEST_ASSERT(vt_bad1 == NULL, "Incompatible protocol version 0x00010001 returns NULL");

    const OmmPluginVTable* vt_bad2 = get_vtable(0xFFFFFFFF);
    TEST_ASSERT(vt_bad2 == NULL, "Protocol version 0xFFFFFFFF returns NULL");

    const OmmPluginVTable* vt = get_vtable(OMM_PLUGIN_PROTOCOL_VERSION);
    TEST_ASSERT(vt != NULL, "Valid protocol version 0x00010000 returns non-NULL VTable");
    if (!vt) return 1;

    TEST_ASSERT(vt->protocol_version == OMM_PLUGIN_PROTOCOL_VERSION, "VTable protocol_version matches");
    TEST_ASSERT(vt->init != NULL, "VTable init function pointer is non-NULL");
    TEST_ASSERT(vt->shutdown != NULL, "VTable shutdown function pointer is non-NULL");
    TEST_ASSERT(vt->get_status != NULL, "VTable get_status function pointer is non-NULL");
    TEST_ASSERT(vt->suspend != NULL, "VTable suspend function pointer is non-NULL");
    TEST_ASSERT(vt->resume != NULL, "VTable resume function pointer is non-NULL");
    TEST_ASSERT(vt->can_handle != NULL, "VTable can_handle function pointer is non-NULL");
    TEST_ASSERT(vt->open_stream != NULL, "VTable open_stream function pointer is non-NULL");
    TEST_ASSERT(vt->read_stream != NULL, "VTable read_stream function pointer is non-NULL");
    TEST_ASSERT(vt->seek_stream != NULL, "VTable seek_stream function pointer is non-NULL");
    TEST_ASSERT(vt->close_stream != NULL, "VTable close_stream function pointer is non-NULL");
    TEST_ASSERT(vt->fetch_lyrics != NULL, "VTable fetch_lyrics function pointer is non-NULL");

    // Initialize plugin
    int32_t rc = vt->init("daemon.lua");
    TEST_ASSERT(rc == OMM_OK, "Plugin initialization returns OMM_OK");

    // 2. Status & Null Pointer Robustness
    printf("\n--- Test Suite 2: Null Pointer & Boundary Hardening ---\n");
    rc = vt->get_status(NULL);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "get_status(NULL) returns OMM_ERR_INVALID_PARAM (-2)");

    OmmPluginStatus status;
    rc = vt->get_status(&status);
    TEST_ASSERT(rc == OMM_OK, "get_status(&status) returns OMM_OK");
    TEST_ASSERT(status.protocol_version == OMM_PLUGIN_PROTOCOL_VERSION, "Status protocol version valid");

    TEST_ASSERT(vt->can_handle(NULL) == 0, "can_handle(NULL) returns 0 without crashing");
    TEST_ASSERT(vt->can_handle("") == 0, "can_handle(\"\") returns 0");
    TEST_ASSERT(vt->can_handle("file:///tmp/test.flac") == 0, "can_handle(file://) returns 0");
    TEST_ASSERT(vt->can_handle("mineral://track/123") == 1, "can_handle(mineral://) returns 1");
    TEST_ASSERT(vt->can_handle("netease://track/456") == 1, "can_handle(netease://) returns 1");
    TEST_ASSERT(vt->can_handle("bilibili://video/789") == 1, "can_handle(bilibili://) returns 1");

    OmmStreamHandle handle = NULL;
    rc = vt->open_stream(NULL, &handle);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "open_stream(NULL, &handle) returns OMM_ERR_INVALID_PARAM");

    rc = vt->open_stream("mineral://test", NULL);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "open_stream(uri, NULL) returns OMM_ERR_INVALID_PARAM");

    rc = vt->open_stream("unsupported_scheme://foo", &handle);
    TEST_ASSERT(rc == OMM_ERR_UNSUPPORTED_URI, "open_stream(unsupported_scheme) returns OMM_ERR_UNSUPPORTED_URI (-4)");

    // Invalid handle tests
    uint8_t dummy_buf[128];
    size_t out_read = 0;
    rc = vt->read_stream(NULL, dummy_buf, sizeof(dummy_buf), &out_read);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "read_stream(NULL, buf) returns OMM_ERR_INVALID_PARAM");

    rc = vt->read_stream((OmmStreamHandle)0x12345678, dummy_buf, sizeof(dummy_buf), &out_read);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "read_stream(bogus_handle) returns OMM_ERR_INVALID_PARAM");

    rc = vt->read_stream((OmmStreamHandle)0x12345678, NULL, sizeof(dummy_buf), &out_read);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "read_stream(bogus_handle, NULL, ...) returns OMM_ERR_INVALID_PARAM");

    rc = vt->read_stream((OmmStreamHandle)0x12345678, dummy_buf, sizeof(dummy_buf), NULL);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "read_stream(..., NULL out_read) returns OMM_ERR_INVALID_PARAM");

    int64_t out_pos = 0;
    rc = vt->seek_stream(NULL, 0, 0, &out_pos);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "seek_stream(NULL, ...) returns OMM_ERR_INVALID_PARAM");

    rc = vt->seek_stream((OmmStreamHandle)0x12345678, 0, 0, NULL);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "seek_stream(..., NULL out_pos) returns OMM_ERR_INVALID_PARAM");

    rc = vt->close_stream(NULL);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "close_stream(NULL) returns OMM_ERR_INVALID_PARAM");

    rc = vt->close_stream((OmmStreamHandle)0x12345678);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "close_stream(bogus_handle) returns OMM_ERR_INVALID_PARAM");

    // 3. 200ms Ring Buffer Underrun Timeout Timing Verification
    printf("\n--- Test Suite 3: 200ms Underrun Timeout Accurate Verification ---\n");
    OmmStreamHandle timeout_handle = NULL;
    rc = vt->open_stream("mineral://track/underrun_test", &timeout_handle);
    TEST_ASSERT(rc == OMM_OK && timeout_handle != NULL, "open_stream(mineral://track/underrun_test) succeeded");

    uint64_t t_start = get_time_ms();
    out_read = 0;
    rc = vt->read_stream(timeout_handle, dummy_buf, sizeof(dummy_buf), &out_read);
    uint64_t elapsed_ms = get_time_ms() - t_start;

    TEST_ASSERT(rc == OMM_ERR_STREAM_TIMEOUT, "read_stream on underrun stream returns OMM_ERR_STREAM_TIMEOUT (-7)");
    TEST_ASSERT(elapsed_ms >= 190 && elapsed_ms <= 260, "Underrun timeout duration was ~200ms");
    printf("    -> Elapsed underrun wait: %lu ms\n", elapsed_ms);

    rc = vt->close_stream(timeout_handle);
    TEST_ASSERT(rc == OMM_OK, "close_stream(timeout_handle) returns OMM_OK");

    // 4. Concurrent Read vs Close Race Condition Stress Test
    printf("\n--- Test Suite 4: Concurrent Stream Read vs Close Race Stress ---\n");
    int race_iterations = 50;
    int race_clean_close = 0;

    for (int iter = 0; iter < race_iterations; iter++) {
        OmmStreamHandle stream_h = NULL;
        rc = vt->open_stream("mineral://track/race_stream", &stream_h);
        if (rc != OMM_OK || !stream_h) {
            continue;
        }

        read_worker_arg_t worker_arg = {
            .vtable = vt,
            .handle = stream_h,
            .stop = false,
            .read_count = 0,
            .timeout_count = 0,
            .eof_count = 0,
            .err_count = 0,
        };

        pthread_t th;
        pthread_create(&th, NULL, read_stream_worker, &worker_arg);

        // Let the worker read for a random duration between 1ms and 10ms
        usleep(1000 + (rand() % 8000));

        // Abruptly close the stream from the main thread while worker is reading
        int32_t close_rc = vt->close_stream(stream_h);
        worker_arg.stop = true;

        pthread_join(th, NULL);

        if (close_rc == OMM_OK) {
            race_clean_close++;
        }
    }
    TEST_ASSERT(race_clean_close == race_iterations, "All 50 concurrent read-vs-close iterations closed cleanly without crash/deadlock");

    // 5. Suspend & Resume Lifecycle under Stream Activity
    printf("\n--- Test Suite 5: Suspend & Resume Lifecycle Stress ---\n");
    OmmStreamHandle active_h = NULL;
    rc = vt->open_stream("mineral://track/lifecycle_test", &active_h);
    TEST_ASSERT(rc == OMM_OK && active_h != NULL, "Opened active stream before suspend");

    rc = vt->suspend();
    TEST_ASSERT(rc == OMM_OK, "vt->suspend() returned OMM_OK");

    // Reading from a suspended engine should immediately return OMM_ERR_SUSPENDED (-8)
    out_read = 0;
    rc = vt->read_stream(active_h, dummy_buf, sizeof(dummy_buf), &out_read);
    TEST_ASSERT(rc == OMM_ERR_SUSPENDED || rc == OMM_ERR_STREAM_EOF || rc == OMM_ERR_INVALID_PARAM, 
                "read_stream on suspended plugin returned OMM_ERR_SUSPENDED or invalid handle");

    rc = vt->resume();
    TEST_ASSERT(rc == OMM_OK, "vt->resume() returned OMM_OK");

    // 6. Lyrics Buffer Overflow & Boundary Hardening
    printf("\n--- Test Suite 6: Lyrics Fetching Buffer Boundary Hardening ---\n");
    char lyric_buf[256];
    size_t out_len = 0;

    rc = vt->fetch_lyrics(NULL, lyric_buf, sizeof(lyric_buf), &out_len);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "fetch_lyrics(NULL, ...) returns OMM_ERR_INVALID_PARAM");

    rc = vt->fetch_lyrics("mineral://track/lyrics_test", NULL, sizeof(lyric_buf), &out_len);
    TEST_ASSERT(rc == OMM_ERR_INVALID_PARAM, "fetch_lyrics(..., NULL buf) returns OMM_ERR_INVALID_PARAM");

    rc = vt->fetch_lyrics("mineral://track/lyrics_test", lyric_buf, 0, &out_len);
    TEST_ASSERT(rc == OMM_ERR_BUFFER_TOO_SMALL || rc == OMM_ERR_INVALID_PARAM, 
                "fetch_lyrics with buf_len = 0 returns OMM_ERR_BUFFER_TOO_SMALL");

    rc = vt->fetch_lyrics("mineral://track/lyrics_test", lyric_buf, 4, &out_len);
    TEST_ASSERT(rc == OMM_ERR_BUFFER_TOO_SMALL, "fetch_lyrics with tiny buffer returns OMM_ERR_BUFFER_TOO_SMALL");

    rc = vt->fetch_lyrics("mineral://track/lyrics_test", lyric_buf, sizeof(lyric_buf), &out_len);
    TEST_ASSERT(rc == OMM_OK && out_len > 0, "fetch_lyrics with adequate buffer returns OMM_OK with valid length");

    printf("\n======================================================================\n");
    printf("   C-ABI STRESS RESULTS: %d Run, %d Passed, %d Failed\n", g_tests_run, g_tests_passed, g_tests_failed);
    printf("======================================================================\n");

    dlclose(lib);
    return (g_tests_failed == 0) ? 0 : 1;
}
