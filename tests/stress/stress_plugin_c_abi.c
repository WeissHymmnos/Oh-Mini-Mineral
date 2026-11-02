//! Empirical C-ABI Stress Harness for libomm_mineral.so
//! Milestone 2 Challenger 1: Adversarial Stress Test

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <dlfcn.h>
#include <assert.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include "omm_abi.h"

static double get_elapsed_ms(struct timespec* start, struct timespec* end) {
    return (end->tv_sec - start->tv_sec) * 1000.0 + (end->tv_nsec - start->tv_nsec) / 1000000.0;
}

static const OmmPluginVTable* g_vtable = NULL;

// ============================================================================
// Test 1: Full 10MB Streaming Throughput & Integrity via C-ABI
// ============================================================================
static void test_streaming_throughput_10mb(void) {
    printf("\n--- [TEST 1] 10MB Continuous Streaming Throughput & Integrity ---\n");
    OmmStreamHandle handle = NULL;
    int32_t rc = g_vtable->open_stream("mineral://stream/benchmark_10mb", &handle);
    assert(rc == OMM_OK && handle != NULL);

    uint8_t buffer[16384];
    size_t total_read = 0;
    size_t corruption_count = 0;

    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    while (1) {
        size_t out_read = 0;
        rc = g_vtable->read_stream(handle, buffer, sizeof(buffer), &out_read);
        if (rc == OMM_OK && out_read == 0) {
            // EOF reached
            break;
        }
        if (rc != OMM_OK) {
            printf("[FAIL] read_stream returned error code %d at offset %zu\n", rc, total_read);
            break;
        }

        // Verify synthetic pattern (0x55)
        for (size_t i = 0; i < out_read; ++i) {
            if (buffer[i] != 0x55) {
                corruption_count++;
            }
        }
        total_read += out_read;
    }

    clock_gettime(CLOCK_MONOTONIC, &t_end);
    double elapsed_s = get_elapsed_ms(&t_start, &t_end) / 1000.0;
    double mb = (double)total_read / (1024.0 * 1024.0);
    double rate = mb / elapsed_s;

    printf("    -> Streamed %.2f MB in %.3f s (Throughput: %.2f MB/s)\n", mb, elapsed_s, rate);
    printf("    -> Corruptions: %zu\n", corruption_count);

    assert(total_read == 10 * 1024 * 1024);
    assert(corruption_count == 0);
    assert(rate > 20.0); // Must exceed 20 MB/s baseline throughput

    rc = g_vtable->close_stream(handle);
    assert(rc == OMM_OK);
    printf("    -> [PASS] 10MB streaming integrity and throughput verified.\n");
}

// ============================================================================
// Test 2: 200ms Timeout Underrun Accuracy & Stability (10 Iterations)
// ============================================================================
static void test_timeout_underrun_accuracy(void) {
    printf("\n--- [TEST 2] 200ms Read Timeout Underrun Defense (10 Iterations) ---\n");
    OmmStreamHandle handle = NULL;
    int32_t rc = g_vtable->open_stream("mineral://stream/timeout_stress", &handle);
    assert(rc == OMM_OK && handle != NULL);

    uint8_t buffer[1024];
    double durations[10];
    double sum = 0.0;
    double min_d = 1e9, max_d = 0.0;

    for (int i = 0; i < 10; ++i) {
        struct timespec t_start, t_end;
        size_t out_read = 999;
        clock_gettime(CLOCK_MONOTONIC, &t_start);
        rc = g_vtable->read_stream(handle, buffer, sizeof(buffer), &out_read);
        clock_gettime(CLOCK_MONOTONIC, &t_end);

        double elapsed = get_elapsed_ms(&t_start, &t_end);
        durations[i] = elapsed;
        sum += elapsed;
        if (elapsed < min_d) min_d = elapsed;
        if (elapsed > max_d) max_d = elapsed;

        printf("    Iteration %d: rc=%d, out_read=%zu, elapsed=%.3f ms\n", i, rc, out_read, elapsed);
        assert(rc == OMM_ERR_STREAM_TIMEOUT);
        assert(out_read == 0);
        // Acceptance requirement: 200ms +/- 15ms -> [185.0ms, 215.0ms]
        assert(elapsed >= 185.0 && elapsed <= 215.0);
    }

    double mean = sum / 10.0;
    printf("    -> Min: %.3f ms, Max: %.3f ms, Mean: %.3f ms\n", min_d, max_d, mean);
    assert(mean >= 195.0 && mean <= 205.0);

    rc = g_vtable->close_stream(handle);
    assert(rc == OMM_OK);
    printf("    -> [PASS] 200ms read timeout underrun defense strictly within [185ms, 215ms].\n");
}

// ============================================================================
// Test 3: Lock Contention / Thread Stalling During 200ms Timeout Underrun
// ============================================================================
typedef struct {
    OmmStreamHandle handle;
    double reader_elapsed;
    int reader_rc;
} timeout_thread_arg_t;

static void* timeout_reader_thread(void* arg) {
    timeout_thread_arg_t* t = (timeout_thread_arg_t*)arg;
    uint8_t buf[256];
    size_t out_read = 0;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    t->reader_rc = g_vtable->read_stream(t->handle, buf, sizeof(buf), &out_read);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    t->reader_elapsed = get_elapsed_ms(&t0, &t1);
    return NULL;
}

static void test_concurrency_stall_during_timeout(void) {
    printf("\n--- [TEST 3] Concurrency & Lock Contention During 200ms Read Timeout (10,000 Calls) ---\n");
    OmmStreamHandle timeout_handle = NULL;
    int32_t rc = g_vtable->open_stream("mineral://stream/timeout_contention", &timeout_handle);
    assert(rc == OMM_OK && timeout_handle != NULL);

    timeout_thread_arg_t t_arg;
    t_arg.handle = timeout_handle;

    pthread_t th;
    pthread_create(&th, NULL, timeout_reader_thread, &t_arg);

    // Sleep 40ms so reader is well into its 200ms timed wait
    usleep(40000);

    // Concurrently benchmark 10,000 get_status calls while reader is blocked in underrun
    const int num_calls = 10000;
    double min_lat = 1e9, max_lat = 0.0, sum_lat = 0.0;
    int over_50us = 0;

    struct timespec bench_t0, bench_t1;
    clock_gettime(CLOCK_MONOTONIC, &bench_t0);

    for (int i = 0; i < num_calls; ++i) {
        struct timespec s0, s1;
        clock_gettime(CLOCK_MONOTONIC, &s0);
        OmmPluginStatus status;
        rc = g_vtable->get_status(&status);
        clock_gettime(CLOCK_MONOTONIC, &s1);

        assert(rc == OMM_OK);
        assert(status.protocol_version == OMM_PLUGIN_PROTOCOL_VERSION);

        double elapsed_ms = get_elapsed_ms(&s0, &s1);
        sum_lat += elapsed_ms;
        if (elapsed_ms < min_lat) min_lat = elapsed_ms;
        if (elapsed_ms > max_lat) max_lat = elapsed_ms;
        if (elapsed_ms >= 0.050) over_50us++;
    }
    clock_gettime(CLOCK_MONOTONIC, &bench_t1);
    double total_bench_ms = get_elapsed_ms(&bench_t0, &bench_t1);

    pthread_join(th, NULL);
    printf("    -> Reader thread underrun duration: %.3f ms (rc=%d)\n", t_arg.reader_elapsed, t_arg.reader_rc);
    printf("    -> Executed %d concurrent get_status calls in %.3f ms\n", num_calls, total_bench_ms);
    printf("    -> get_status latencies: Min: %.4f ms, Mean: %.4f ms, Max: %.4f ms\n",
           min_lat, sum_lat / num_calls, max_lat);
    printf("    -> Calls >= 0.050 ms: %d / %d\n", over_50us, num_calls);

    assert(t_arg.reader_rc == OMM_ERR_STREAM_TIMEOUT);
    assert(over_50us == 0);
    assert(max_lat < 0.050); // Strictly < 0.050 ms (50 µs)
    printf("    -> [PASS] get_status() is strictly non-blocking (max latency %.4f ms < 0.050 ms).\n", max_lat);

    g_vtable->close_stream(timeout_handle);
}

// ============================================================================
// Test 4: Dynamic Sliding Seek Stress via C-ABI
// ============================================================================
static void test_seek_wraparound_via_c_abi(void) {
    printf("\n--- [TEST 4] Dynamic Sliding Seek Stress via C-ABI ---\n");
    OmmStreamHandle handle = NULL;
    int32_t rc = g_vtable->open_stream("mineral://stream/seek_bench", &handle);
    assert(rc == OMM_OK && handle != NULL);

    // 1. Stream 1MB+ of data (past the 512KB ring buffer capacity)
    uint8_t scratch[32768];
    size_t streamed = 0;
    size_t corruptions = 0;
    while (streamed < 1200000) {
        size_t n = 0;
        rc = g_vtable->read_stream(handle, scratch, sizeof(scratch), &n);
        assert(rc == OMM_OK);
        for (size_t i = 0; i < n; ++i) {
            if (scratch[i] != 0x55) corruptions++;
        }
        streamed += n;
    }
    printf("    -> Successfully streamed %zu bytes through buffer (>1MB). Corruptions: %zu\n", streamed, corruptions);
    assert(streamed >= 1200000);
    assert(corruptions == 0);

    // 2. In-window micro-seek BACKWARD by 16KB
    int64_t micro_back = 0;
    rc = g_vtable->seek_stream(handle, -16384, 1 /* SEEK_CUR */, &micro_back);
    assert(rc == OMM_OK);
    printf("    -> In-window backward micro-seek (-16KB): out_pos = %ld (rc=%d)\n", (long)micro_back, rc);
    assert(micro_back == (int64_t)streamed - 16384);

    // Verify audio bytes returned after backward seek
    size_t read_back = 0;
    rc = g_vtable->read_stream(handle, scratch, 4096, &read_back);
    assert(rc == OMM_OK && read_back == 4096);
    for (size_t i = 0; i < 4096; ++i) {
        if (scratch[i] != 0x55) corruptions++;
    }
    assert(corruptions == 0);
    printf("    -> [PASS] In-window backward micro-seek returned valid data (0 corruptions).\n");

    // 3. In-window micro-seek FORWARD by 8KB
    int64_t micro_fwd = 0;
    rc = g_vtable->seek_stream(handle, 8192, 1 /* SEEK_CUR */, &micro_fwd);
    assert(rc == OMM_OK);
    printf("    -> In-window forward micro-seek (+8KB): out_pos = %ld (rc=%d)\n", (long)micro_fwd, rc);

    size_t read_fwd = 0;
    rc = g_vtable->read_stream(handle, scratch, 4096, &read_fwd);
    assert(rc == OMM_OK && read_fwd == 4096);
    for (size_t i = 0; i < 4096; ++i) {
        if (scratch[i] != 0x55) corruptions++;
    }
    assert(corruptions == 0);
    printf("    -> [PASS] In-window forward micro-seek returned valid data (0 corruptions).\n");

    // 4. Out-of-window seek BACKWARD to byte 50,000 (past 1MB, overwritten)
    int64_t out_50k = 0;
    rc = g_vtable->seek_stream(handle, 50000, 0 /* SEEK_SET */, &out_50k);
    assert(rc == OMM_OK && out_50k == 50000);
    printf("    -> Out-of-window seek to 50KB: rc=%d, out_pos=%ld\n", rc, (long)out_50k);

    // Verify streaming resumes cleanly at byte 50,000
    size_t read_50k = 0;
    rc = g_vtable->read_stream(handle, scratch, 4096, &read_50k);
    assert(rc == OMM_OK && read_50k == 4096);
    for (size_t i = 0; i < 4096; ++i) {
        if (scratch[i] != 0x55) corruptions++;
    }
    assert(corruptions == 0);
    printf("    -> [PASS] Streaming resumed cleanly at byte 50,000 (0 corruptions).\n");

    // 5. Out-of-window seek FORWARD to future byte 2,000,000
    int64_t out_2m = 0;
    rc = g_vtable->seek_stream(handle, 2000000, 0 /* SEEK_SET */, &out_2m);
    assert(rc == OMM_OK && out_2m == 2000000);
    printf("    -> Out-of-window seek to 2MB: rc=%d, out_pos=%ld\n", rc, (long)out_2m);

    // Verify streaming resumes cleanly at byte 2,000,000
    size_t read_2m = 0;
    rc = g_vtable->read_stream(handle, scratch, 4096, &read_2m);
    assert(rc == OMM_OK && read_2m == 4096);
    for (size_t i = 0; i < 4096; ++i) {
        if (scratch[i] != 0x55) corruptions++;
    }
    assert(corruptions == 0);
    printf("    -> [PASS] Streaming resumed cleanly at byte 2,000,000 (0 corruptions).\n");

    g_vtable->close_stream(handle);
    printf("    -> [PASS] Dynamic sliding seek suite passed with 0 corruptions.\n");
}

// ============================================================================
// Test 5: Background Task Lifecycle & Cleanup Under Backpressure
// ============================================================================
static void test_task_lifecycle_under_backpressure(void) {
    printf("\n--- [TEST 5] Task Lifecycle & Cleanup Under Backpressure ---\n");
    OmmStreamHandle handle = NULL;
    int32_t rc = g_vtable->open_stream("mineral://stream/backpressure_close_test", &handle);
    assert(rc == OMM_OK && handle != NULL);

    // Wait 50ms for producer to fill buffer to 85% backpressure
    usleep(50000);

    OmmPluginStatus status_before;
    rc = g_vtable->get_status(&status_before);
    assert(rc == OMM_OK);
    assert(status_before.active_streams >= 1);
    printf("    -> Before close: active_streams = %u\n", status_before.active_streams);

    // Measure close_stream latency
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    rc = g_vtable->close_stream(handle);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double close_elapsed_ms = get_elapsed_ms(&t0, &t1);

    assert(rc == OMM_OK);
    printf("    -> close_stream() completed in %.3f ms\n", close_elapsed_ms);
    assert(close_elapsed_ms < 50.0); // Strictly < 50ms (typically < 1ms)

    // Wait 20ms to allow background task teardown
    usleep(20000);

    OmmPluginStatus status_after;
    rc = g_vtable->get_status(&status_after);
    assert(rc == OMM_OK);
    printf("    -> After close: active_streams = %u\n", status_after.active_streams);
    assert(status_after.active_streams == 0);

    printf("    -> [PASS] close_stream under backpressure completed in %.3f ms (< 50ms) and active_streams = 0.\n", close_elapsed_ms);
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    printf("===============================================================================\n");
    printf("    EMPIRICAL CHALLENGER STRESS HARNESS: RING BUFFER, BACKPRESSURE & SEEK     \n");
    printf("===============================================================================\n");

    void* dl = dlopen("./bin/libomm_mineral.so", RTLD_NOW | RTLD_LOCAL);
    if (!dl) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    omm_plugin_get_vtable_fn get_vtable = (omm_plugin_get_vtable_fn)dlsym(dl, "omm_plugin_get_vtable");
    if (!get_vtable) {
        fprintf(stderr, "dlsym failed: %s\n", dlerror());
        dlclose(dl);
        return 1;
    }

    g_vtable = get_vtable(OMM_PLUGIN_PROTOCOL_VERSION);
    assert(g_vtable != NULL);

    int32_t rc = g_vtable->init(NULL);
    assert(rc == OMM_OK);

    test_streaming_throughput_10mb();
    test_timeout_underrun_accuracy();
    test_concurrency_stall_during_timeout();
    test_seek_wraparound_via_c_abi();
    test_task_lifecycle_under_backpressure();

    rc = g_vtable->shutdown();
    assert(rc == OMM_OK);
    dlclose(dl);

    printf("\n===============================================================================\n");
    printf(">>> ALL C-ABI EMPIRICAL STRESS TESTS EXECUTED COMPREHENSIVELY <<<\n");
    printf("===============================================================================\n");
    return 0;
}

