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
#include "omm_abi.h"

static double get_elapsed_ms(struct timespec* start, struct timespec* end) {
    return (end->tv_sec - start->tv_sec) * 1000.0 + (end->tv_nsec - start->tv_nsec) / 1000000.0;
}

int main(void) {
    printf("===============================================================================\n");
    printf("           OH-MY-MINERAL C-ABI DYNAMIC PLUGIN VERIFICATION HARNESS            \n");
    printf("===============================================================================\n\n");

    const char* lib_paths[] = {
        "./bin/libomm_mineral.so",
        "./target/release/libomm_mineral.so",
        "../bin/libomm_mineral.so",
        NULL
    };

    void* dl_handle = NULL;
    const char* loaded_path = NULL;
    for (int i = 0; lib_paths[i] != NULL; ++i) {
        if (access(lib_paths[i], R_OK) == 0) {
            dl_handle = dlopen(lib_paths[i], RTLD_NOW | RTLD_LOCAL);
            if (dl_handle != NULL) {
                loaded_path = lib_paths[i];
                break;
            }
        }
    }

    if (dl_handle == NULL) {
        fprintf(stderr, "[FAIL] dlopen failed to load libomm_mineral.so: %s\n", dlerror());
        return 1;
    }
    printf("[1] Dynamically loaded %s successfully.\n", loaded_path);

    /* 1. Resolve omm_plugin_get_vtable */
    omm_plugin_get_vtable_fn get_vtable = (omm_plugin_get_vtable_fn)dlsym(dl_handle, "omm_plugin_get_vtable");
    char* err = dlerror();
    if (err != NULL || get_vtable == NULL) {
        fprintf(stderr, "[FAIL] dlsym failed for omm_plugin_get_vtable: %s\n", err ? err : "NULL");
        dlclose(dl_handle);
        return 1;
    }
    printf("[2] Resolved export symbol 'omm_plugin_get_vtable'.\n");

    /* 2. Protocol Version Negotiation */
    printf("[3] Verifying Protocol Version Negotiation...\n");
    assert(get_vtable(0) == NULL);
    assert(get_vtable(0xFFFFFFFF) == NULL);
    assert(get_vtable(0x00020000) == NULL);

    const OmmPluginVTable* vtable = get_vtable(OMM_PLUGIN_PROTOCOL_VERSION);
    assert(vtable != NULL);
    assert(vtable->protocol_version == OMM_PLUGIN_PROTOCOL_VERSION);
    printf("    -> Incompatible versions rejected with NULL.\n");
    printf("    -> Protocol version 0x%08X returned valid VTable.\n", OMM_PLUGIN_PROTOCOL_VERSION);

    /* 3. VTable Function Pointer Verification */
    printf("[4] Verifying VTable Function Pointers...\n");
    assert(vtable->init != NULL);
    assert(vtable->shutdown != NULL);
    assert(vtable->get_status != NULL);
    assert(vtable->suspend != NULL);
    assert(vtable->resume != NULL);
    assert(vtable->can_handle != NULL);
    assert(vtable->open_stream != NULL);
    assert(vtable->read_stream != NULL);
    assert(vtable->seek_stream != NULL);
    assert(vtable->close_stream != NULL);
    assert(vtable->fetch_lyrics != NULL);
    printf("    -> All 11 function pointers are non-NULL.\n");

    /* 4. Plugin Init & Lifecycle Status */
    printf("[5] Testing Plugin Lifecycle Initialization (init & get_status)...\n");
    int32_t rc = vtable->init("daemon.lua");
    assert(rc == OMM_OK);

    OmmPluginStatus status;
    memset(&status, 0, sizeof(status));
    rc = vtable->get_status(&status);
    assert(rc == OMM_OK);
    assert(status.protocol_version == OMM_PLUGIN_PROTOCOL_VERSION);
    assert(status.state == OMM_PLUGIN_LAZY_WAKEUP);
    assert(status.active_streams == 0);
    assert(status.rss_bytes > 0);
    printf("    -> Status: state=%u (LAZY_WAKEUP), rss_bytes=%lu, active_streams=%u\n",
           status.state, (unsigned long)status.rss_bytes, status.active_streams);

    /* 5. URI Routing (can_handle) */
    printf("[6] Testing URI Scheme Support (can_handle)...\n");
    assert(vtable->can_handle("mineral://stream/track_12345") == 1);
    assert(vtable->can_handle("netease://song/67890") == 1);
    assert(vtable->can_handle("bilibili://video/av123456") == 1);
    assert(vtable->can_handle("applemusic://track/999") == 1);
    assert(vtable->can_handle("https://example.com/audio.flac") == 1);
    assert(vtable->can_handle("file:///music/local.flac") == 0);
    assert(vtable->can_handle("ftp://example.com/song.mp3") == 0);
    assert(vtable->can_handle(NULL) == 0);
    printf("    -> can_handle correctly routes online schemes and rejects local/unsupported schemes.\n");

    /* 6. Active Stream Open, Read, Seek, Close */
    printf("[7] Testing Active Streaming (open, read, seek, close)...\n");
    OmmStreamHandle handle = NULL;
    rc = vtable->open_stream("mineral://stream/test_online_audio", &handle);
    assert(rc == OMM_OK);
    assert(handle != NULL);

    rc = vtable->get_status(&status);
    assert(rc == OMM_OK);
    assert(status.active_streams == 1);
    assert(status.state == OMM_PLUGIN_ACTIVE);
    printf("    -> Stream opened: handle=%p, state=%u (ACTIVE), active_streams=%u\n",
           handle, status.state, status.active_streams);

    uint8_t read_buffer[4096];
    size_t out_read = 0;
    rc = vtable->read_stream(handle, read_buffer, sizeof(read_buffer), &out_read);
    assert(rc == OMM_OK);
    assert(out_read > 0);
    printf("    -> Read %zu bytes successfully.\n", out_read);

    // Seek in-window
    int64_t out_pos = 0;
    rc = vtable->seek_stream(handle, 2048, 0 /* SEEK_SET */, &out_pos);
    assert(rc == OMM_OK);
    assert(out_pos == 2048);
    printf("    -> In-window seek to 2048 returned pos %ld\n", (long)out_pos);

    // Seek out-of-window
    rc = vtable->seek_stream(handle, 2 * 1024 * 1024, 0 /* SEEK_SET */, &out_pos);
    assert(rc == OMM_OK);
    assert(out_pos == 2 * 1024 * 1024);
    printf("    -> Out-of-window seek to 2MB returned pos %ld\n", (long)out_pos);

    // Seek invalid bounds
    rc = vtable->seek_stream(handle, -500, 0 /* SEEK_SET */, &out_pos);
    assert(rc == OMM_ERR_INVALID_PARAM);

    // Close stream
    rc = vtable->close_stream(handle);
    assert(rc == OMM_OK);
    rc = vtable->get_status(&status);
    assert(rc == OMM_OK);
    assert(status.active_streams == 0);
    printf("    -> Stream closed successfully.\n");

    /* 7. 200ms Timeout Underrun Guard */
    printf("[8] Testing 200ms Ring Buffer Read Timeout Underrun Guard...\n");
    OmmStreamHandle timeout_handle = NULL;
    rc = vtable->open_stream("mineral://stream/timeout_simulation", &timeout_handle);
    assert(rc == OMM_OK);
    assert(timeout_handle != NULL);

    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);
    rc = vtable->read_stream(timeout_handle, read_buffer, sizeof(read_buffer), &out_read);
    clock_gettime(CLOCK_MONOTONIC, &t_end);
    double elapsed_ms = get_elapsed_ms(&t_start, &t_end);

    printf("    -> read_stream returned code %d after %.2f ms\n", rc, elapsed_ms);
    assert(rc == OMM_ERR_STREAM_TIMEOUT);
    assert(out_read == 0);
    assert(elapsed_ms >= 180.0 && elapsed_ms <= 400.0);
    printf("    -> [PASS] Verified 200ms timed wait returned OMM_ERR_STREAM_TIMEOUT (-7).\n");

    rc = vtable->close_stream(timeout_handle);
    assert(rc == OMM_OK);

    /* 8. Fetch Lyrics (Caller-Allocated Buffer) */
    printf("[9] Testing Synchronized Lyrics (fetch_lyrics & caller-allocated buffer)...\n");
    size_t needed_len = 0;
    // Sizing probe with buf_len = 0
    rc = vtable->fetch_lyrics("mineral://stream/test", NULL, 0, &needed_len);
    assert(rc == OMM_ERR_BUFFER_TOO_SMALL);
    assert(needed_len > 0);
    printf("    -> Sizing probe returned OMM_ERR_BUFFER_TOO_SMALL with needed_len = %zu\n", needed_len);

    // Small buffer test
    char small_buf[16];
    size_t small_out = 0;
    rc = vtable->fetch_lyrics("mineral://stream/test", small_buf, sizeof(small_buf), &small_out);
    assert(rc == OMM_ERR_BUFFER_TOO_SMALL);

    // Adequate buffer test
    char lyrics_buf[1024];
    size_t lyrics_out = 0;
    memset(lyrics_buf, 0xFF, sizeof(lyrics_buf));
    rc = vtable->fetch_lyrics("mineral://stream/test", lyrics_buf, sizeof(lyrics_buf), &lyrics_out);
    assert(rc == OMM_OK);
    assert(lyrics_out == needed_len);
    assert(lyrics_buf[lyrics_out] == 0); // Null terminator
    assert(strstr(lyrics_buf, "Lyrics") != NULL);
    assert(strstr(lyrics_buf, "[00:") != NULL || strstr(lyrics_buf, "[01:") != NULL);
    printf("    -> Copied %zu bytes of synchronized LRC lyrics cleanly.\n", lyrics_out);

    /* 9. Shallow Suspend & Memory Footprint (< 0.3 MB) */
    printf("[10] Testing Shallow Suspend (suspend, malloc_trim, RSS budget < 0.3 MB)...\n");
    rc = vtable->suspend();
    assert(rc == OMM_OK);

    // Suspend idempotence
    rc = vtable->suspend();
    assert(rc == OMM_OK);

    rc = vtable->get_status(&status);
    assert(rc == OMM_OK);
    assert(status.state == OMM_PLUGIN_SUSPENDED);
    assert(status.active_streams == 0);
    printf("    -> Suspended state: state=%u (SUSPENDED), rss_bytes=%lu\n",
           status.state, (unsigned long)status.rss_bytes);
    assert(status.rss_bytes < 300 * 1024); // strictly < 300 KB budget (< 0.3 MB)
    printf("    -> [PASS] RSS footprint %lu bytes is below 300 KB budget.\n", (unsigned long)status.rss_bytes);

    // Resume
    rc = vtable->resume();
    assert(rc == OMM_OK);
    rc = vtable->get_status(&status);
    assert(rc == OMM_OK);
    assert(status.state == OMM_PLUGIN_LAZY_WAKEUP || status.state == OMM_PLUGIN_ACTIVE);
    printf("    -> Resumed state: state=%u\n", status.state);

    /* 10. Zero-Panic FFI Boundaries */
    printf("[11] Testing Zero-Panic Boundary Guard & Invalid Params...\n");
    assert(vtable->open_stream(NULL, NULL) == OMM_ERR_INVALID_PARAM);
    assert(vtable->read_stream(NULL, NULL, 0, NULL) == OMM_ERR_INVALID_PARAM);
    assert(vtable->seek_stream(NULL, 0, 0, NULL) == OMM_ERR_INVALID_PARAM);
    assert(vtable->close_stream(NULL) == OMM_ERR_INVALID_PARAM);
    assert(vtable->fetch_lyrics(NULL, NULL, 0, NULL) == OMM_ERR_INVALID_PARAM);
    printf("    -> All invalid pointers cleanly handled with OMM_ERR_INVALID_PARAM (-2).\n");

    /* 11. Shutdown & Unload */
    printf("[12] Testing Shutdown...\n");
    rc = vtable->shutdown();
    assert(rc == OMM_OK);
    rc = vtable->get_status(&status);
    assert(rc == OMM_OK);
    assert(status.state == OMM_PLUGIN_UNLOADED);
    assert(status.rss_bytes == 0);

    dlclose(dl_handle);
    printf("    -> Plugin unloaded cleanly.\n\n");

    printf("===============================================================================\n");
    printf(">>> ALL C-ABI DYNAMIC PLUGIN VERIFICATION TESTS PASSED SUCCESSFULLY! <<<\n");
    printf("===============================================================================\n");
    return 0;
}
