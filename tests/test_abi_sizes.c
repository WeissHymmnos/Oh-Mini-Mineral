#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <assert.h>
#include "omm_abi.h"

int main(void) {
    printf("=== GCC ABI Sizes & Offsets Verification ===\n");

    /* 1. Size Assertions */
    printf("[1] Checking Structure Sizes...\n");
    printf("  sizeof(omm_condensed_track_t) = %zu (expected 480)\n", sizeof(omm_condensed_track_t));
    assert(sizeof(omm_condensed_track_t) == 480);

    printf("  sizeof(omm_packet_payload_t)  = %zu (expected 496)\n", sizeof(omm_packet_payload_t));
    assert(sizeof(omm_packet_payload_t) == 496);

    printf("  sizeof(omm_packet_t)          = %zu (expected 512)\n", sizeof(omm_packet_t));
    assert(sizeof(omm_packet_t) == 512);
    assert(_Alignof(omm_packet_t) == 8);

    printf("  sizeof(omm_shm_t)             = %zu (expected 65536)\n", sizeof(omm_shm_t));
    assert(sizeof(omm_shm_t) == 65536);
    assert(_Alignof(omm_shm_t) == 8);

    printf("  sizeof(omm_track_record_t)    = %zu (expected 512)\n", sizeof(omm_track_record_t));
    assert(sizeof(omm_track_record_t) == 512);
    assert(_Alignof(omm_track_record_t) == 512);

    printf("  sizeof(OmmPluginStatus)       = %zu (expected 24)\n", sizeof(OmmPluginStatus));
    assert(sizeof(OmmPluginStatus) == 24);

    printf("  sizeof(OmmPluginVTable)       = %zu (expected 96)\n", sizeof(OmmPluginVTable));
    assert(sizeof(OmmPluginVTable) == 96);

    /* 2. Packet Offsets */
    printf("[2] Checking omm_packet_t Offsets...\n");
    assert(offsetof(omm_packet_t, magic) == 0);
    assert(offsetof(omm_packet_t, version) == 4);
    assert(offsetof(omm_packet_t, opcode) == 6);
    assert(offsetof(omm_packet_t, seq_id) == 8);
    assert(offsetof(omm_packet_t, status_code) == 12);
    assert(offsetof(omm_packet_t, payload) == 16);

    /* 3. SHM Offsets */
    printf("[3] Checking omm_shm_t Offsets...\n");
    assert(offsetof(omm_shm_t, magic) == 0x0000);
    assert(offsetof(omm_shm_t, version) == 0x0004);
    assert(offsetof(omm_shm_t, seqlock) == 0x0008);
    assert(offsetof(omm_shm_t, playback_state) == 0x0010);
    assert(offsetof(omm_shm_t, playback_flags) == 0x0014);
    assert(offsetof(omm_shm_t, current_track_id) == 0x0018);
    assert(offsetof(omm_shm_t, position_ms) == 0x001C);
    assert(offsetof(omm_shm_t, duration_ms) == 0x0020);
    assert(offsetof(omm_shm_t, volume) == 0x0024);
    assert(offsetof(omm_shm_t, sample_rate) == 0x0028);
    assert(offsetof(omm_shm_t, channels) == 0x002C);
    assert(offsetof(omm_shm_t, bit_depth) == 0x002E);
    assert(offsetof(omm_shm_t, buffer_fill_ratio) == 0x0030);
    assert(offsetof(omm_shm_t, underrun_counter) == 0x0034);
    assert(offsetof(omm_shm_t, plugin_state) == 0x0038);
    assert(offsetof(omm_shm_t, plugin_idle_secs) == 0x003C);
    assert(offsetof(omm_shm_t, plugin_rss_bytes) == 0x0040);
    assert(offsetof(omm_shm_t, daemon_pid) == 0x0048);
    assert(offsetof(omm_shm_t, daemon_uptime_secs) == 0x004C);
    assert(offsetof(omm_shm_t, total_tracks) == 0x0050);
    assert(offsetof(omm_shm_t, reserved_header) == 0x0054);
    assert(offsetof(omm_shm_t, track_title) == 0x0080);
    assert(offsetof(omm_shm_t, track_artist) == 0x0100);
    assert(offsetof(omm_shm_t, track_album) == 0x0180);
    assert(offsetof(omm_shm_t, virtual_uri) == 0x0200);
    assert(offsetof(omm_shm_t, lyric_current) == 0x0300);
    assert(offsetof(omm_shm_t, lyric_next) == 0x0400);
    assert(offsetof(omm_shm_t, lyric_translation) == 0x0500);
    assert(offsetof(omm_shm_t, lyric_timestamp_ms) == 0x0600);
    assert(offsetof(omm_shm_t, lyric_line_idx) == 0x0604);
    assert(offsetof(omm_shm_t, reserved_lyric) == 0x0608);
    assert(offsetof(omm_shm_t, spectrum_bands) == 0x0700);
    assert(offsetof(omm_shm_t, spectrum_seq) == 0x0704);
    assert(offsetof(omm_shm_t, reserved_spec) == 0x0708);
    assert(offsetof(omm_shm_t, spectrum_mags) == 0x0800);
    assert(offsetof(omm_shm_t, spectrum_peaks) == 0x0900);
    assert(offsetof(omm_shm_t, quantized_bars) == 0x0A00);
    assert(offsetof(omm_shm_t, quantized_peaks) == 0x0A40);
    assert(offsetof(omm_shm_t, reserved_pad) == 0x0A80);
    assert(offsetof(omm_shm_t, oscilloscope_tap) == 0x0B00);
    assert(offsetof(omm_shm_t, reserved_payload) == 0x1300);

    /* 4. Track Record Offsets */
    printf("[4] Checking omm_track_record_t Offsets...\n");
    assert(offsetof(omm_track_record_t, track_id) == 0);
    assert(offsetof(omm_track_record_t, duration_ms) == 4);
    assert(offsetof(omm_track_record_t, year) == 8);
    assert(offsetof(omm_track_record_t, track_no) == 10);
    assert(offsetof(omm_track_record_t, bitrate_kbps) == 12);
    assert(offsetof(omm_track_record_t, format_tag) == 14);
    assert(offsetof(omm_track_record_t, title) == 16);
    assert(offsetof(omm_track_record_t, artist) == 144);
    assert(offsetof(omm_track_record_t, album) == 240);
    assert(offsetof(omm_track_record_t, relative_path) == 336);
    assert(offsetof(omm_track_record_t, tfidf_vector) == 464);
    assert(offsetof(omm_track_record_t, vector_norm) == 496);
    assert(offsetof(omm_track_record_t, reserved) == 500);

    /* 5. Plugin Status & VTable Offsets */
    printf("[5] Checking Plugin Status & VTable Offsets...\n");
    assert(offsetof(OmmPluginStatus, protocol_version) == 0);
    assert(offsetof(OmmPluginStatus, state) == 4);
    assert(offsetof(OmmPluginStatus, rss_bytes) == 8);
    assert(offsetof(OmmPluginStatus, active_streams) == 16);
    assert(offsetof(OmmPluginStatus, idle_seconds) == 20);

    assert(offsetof(OmmPluginVTable, protocol_version) == 0);
    assert(offsetof(OmmPluginVTable, init) == 8);
    assert(offsetof(OmmPluginVTable, fetch_lyrics) == 88);

    printf("ALL GCC ABI STATIC ASSERTIONS PASSED!\n");
    return 0;
}
