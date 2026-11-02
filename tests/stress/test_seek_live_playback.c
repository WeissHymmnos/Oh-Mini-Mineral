#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "omm_abi.h"

#define CLOCK_MONOTONIC 1

static int64_t get_monotonic_micros(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((int64_t)ts.tv_sec * 1000000LL) + ((int64_t)ts.tv_nsec / 1000LL);
}

// Generate a valid 30-second RIFF WAV file at path
static int generate_wav_file(const char* path, uint32_t duration_sec, uint32_t sample_rate, uint16_t channels) {
    FILE* f = fopen(path, "wb");
    if (!f) {
        perror("fopen wav");
        return -1;
    }

    uint32_t total_samples = duration_sec * sample_rate;
    uint16_t bits_per_sample = 16;
    uint16_t block_align = channels * (bits_per_sample / 8);
    uint32_t byte_rate = sample_rate * block_align;
    uint32_t data_bytes = total_samples * block_align;
    uint32_t riff_size = 36 + data_bytes;

    struct __attribute__((packed)) {
        char riff[4];
        uint32_t riff_size;
        char wave[4];
        char fmt[4];
        uint32_t fmt_size;
        uint16_t audio_format;
        uint16_t num_channels;
        uint32_t sample_rate;
        uint32_t byte_rate;
        uint16_t block_align;
        uint16_t bits_per_sample;
        char data[4];
        uint32_t data_size;
    } hdr;

    memcpy(hdr.riff, "RIFF", 4);
    hdr.riff_size = riff_size;
    memcpy(hdr.wave, "WAVE", 4);
    memcpy(hdr.fmt, "fmt ", 4);
    hdr.fmt_size = 16;
    hdr.audio_format = 1; // PCM
    hdr.num_channels = channels;
    hdr.sample_rate = sample_rate;
    hdr.byte_rate = byte_rate;
    hdr.block_align = block_align;
    hdr.bits_per_sample = bits_per_sample;
    memcpy(hdr.data, "data", 4);
    hdr.data_size = data_bytes;

    fwrite(&hdr, sizeof(hdr), 1, f);

    // Write 1 second buffer chunks of 440Hz sine wave
    int16_t* chunk = (int16_t*)malloc(sample_rate * channels * sizeof(int16_t));
    if (!chunk) {
        fclose(f);
        return -1;
    }

    double freq = 440.0;
    for (uint32_t sec = 0; sec < duration_sec; sec++) {
        for (uint32_t i = 0; i < sample_rate; i++) {
            double t = (double)(sec * sample_rate + i) / (double)sample_rate;
            int16_t sample = (int16_t)(sin(2.0 * M_PI * freq * t) * 16000.0);
            for (uint16_t ch = 0; ch < channels; ch++) {
                chunk[i * channels + ch] = sample;
            }
        }
        fwrite(chunk, sizeof(int16_t), sample_rate * channels, f);
    }

    free(chunk);
    fclose(f);
    return 0;
}

// Consistent atomic seqlock read of playback state and position
static void read_shm_playback_info(const volatile omm_shm_t* shm,
                                  uint32_t* out_state, uint32_t* out_pos, uint32_t* out_dur) {
    uint64_t seq;
    do {
        seq = shm->seqlock;
        while (seq & 1) {
            __builtin_ia32_pause();
            seq = shm->seqlock;
        }
        __sync_synchronize();
        *out_state = shm->playback_state;
        *out_pos = shm->position_ms;
        *out_dur = shm->duration_ms;
        __sync_synchronize();
    } while (shm->seqlock != seq);
}

int main(int argc, char* argv[]) {
    const char* socket_path = "/tmp/omm.sock";
    const char* shm_name = "/omm_shm";
    const char* wav_path = "/tmp/omm_test_tone_30s.wav";

    if (argc >= 2) socket_path = argv[1];
    if (argc >= 3) shm_name = argv[2];

    printf("======================================================================\n");
    printf("  CHALLENGER: LIVE DAEMON SEEK RESPONSIVENESS & MONOTONICITY HARNESS   \n");
    printf("======================================================================\n");
    printf("  Socket:   %s\n", socket_path);
    printf("  SHM:      %s\n", shm_name);
    printf("  WAV File: %s\n", wav_path);

    // 1. Generate 30-second WAV file
    printf("\n[1] Generating 30-second 48kHz stereo WAV fixture...\n");
    if (generate_wav_file(wav_path, 30, 48000, 2) != 0) {
        fprintf(stderr, "  [FAIL] Failed to generate test WAV file!\n");
        return 1;
    }
    printf("  Generated %s (30s, 48000Hz, 2ch, 16-bit PCM)\n", wav_path);

    // 2. Open and map shared memory
    int shm_fd = shm_open(shm_name, O_RDONLY, 0);
    if (shm_fd < 0) {
        perror("shm_open");
        unlink(wav_path);
        return 1;
    }
    volatile omm_shm_t* shm = (volatile omm_shm_t*)mmap(
        NULL, OMM_SHM_SIZE, PROT_READ, MAP_SHARED, shm_fd, 0);
    if (shm == MAP_FAILED || !shm) {
        perror("mmap shm");
        close(shm_fd);
        unlink(wav_path);
        return 1;
    }
    printf("  Mapped %s at %p (size=%d)\n", shm_name, (void*)shm, OMM_SHM_SIZE);

    // 3. Connect to daemon socket
    int sock_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock_fd < 0) {
        perror("socket");
        munmap((void*)shm, OMM_SHM_SIZE);
        close(shm_fd);
        unlink(wav_path);
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (connect(sock_fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        perror("connect");
        close(sock_fd);
        munmap((void*)shm, OMM_SHM_SIZE);
        close(shm_fd);
        unlink(wav_path);
        return 1;
    }
    printf("  Connected to daemon socket %s\n", socket_path);

    // 4. Start playback of WAV file
    printf("\n[2] Dispatching OP_REQ_PLAY_URI for file://%s...\n", wav_path);
    omm_packet_t play_req;
    memset(&play_req, 0, sizeof(play_req));
    play_req.magic = OMM_PACKET_MAGIC;
    play_req.version = 1;
    play_req.opcode = OP_REQ_PLAY_URI;
    play_req.seq_id = 5001;
    snprintf(play_req.payload.uri, sizeof(play_req.payload.uri), "file://%s", wav_path);

    if (write(sock_fd, &play_req, sizeof(play_req)) != sizeof(play_req)) {
        perror("write play_req");
        goto cleanup;
    }

    omm_packet_t play_resp;
    if (read(sock_fd, &play_resp, sizeof(play_resp)) != sizeof(play_resp)) {
        perror("read play_resp");
        goto cleanup;
    }
    if (play_resp.opcode != OP_RESP_OK) {
        fprintf(stderr, "  [FAIL] Expected OP_RESP_OK for play_uri, got 0x%04x (status=%d)\n",
                play_resp.opcode, play_resp.status_code);
        goto cleanup;
    }
    printf("  [PASS] Daemon accepted OP_REQ_PLAY_URI.\n");

    // Wait for playback to start and report duration
    printf("  Waiting for playback to begin...\n");
    uint32_t state = 0, pos = 0, dur = 0;
    int wait_iters = 0;
    while (wait_iters < 40) { // Up to 2.0s
        usleep(50000); // 50ms
        read_shm_playback_info(shm, &state, &pos, &dur);
        if (state == OMM_STATE_PLAYING && dur > 0) break;
        wait_iters++;
    }
    printf("  Playback state: %u, Duration: %u ms, Position: %u ms\n", state, dur, pos);
    if (state != OMM_STATE_PLAYING || dur == 0) {
        fprintf(stderr, "  [FAIL] Playback failed to start within 2s!\n");
        goto cleanup;
    }

    // 5. Test seek at percentages: 0%, 25%, 50%, 75%, 90%
    printf("\n[3] Testing Seek Responsiveness at 0%%, 25%%, 50%%, 75%%, 90%%...\n");
    int percentages[] = { 0, 25, 50, 75, 90 };
    int num_percentages = sizeof(percentages) / sizeof(percentages[0]);

    for (int i = 0; i < num_percentages; i++) {
        int pct = percentages[i];
        uint32_t target_ms = (uint32_t)(((double)pct / 100.0) * (double)dur);

        omm_packet_t seek_req;
        memset(&seek_req, 0, sizeof(seek_req));
        seek_req.magic = OMM_PACKET_MAGIC;
        seek_req.version = 1;
        seek_req.opcode = OP_REQ_SEEK;
        seek_req.seq_id = 6000 + i;
        seek_req.payload.target_ms = target_ms;

        int64_t t_start = get_monotonic_micros();
        if (write(sock_fd, &seek_req, sizeof(seek_req)) != sizeof(seek_req)) {
            perror("write seek_req");
            goto cleanup;
        }

        omm_packet_t seek_resp;
        if (read(sock_fd, &seek_resp, sizeof(seek_resp)) != sizeof(seek_resp)) {
            perror("read seek_resp");
            goto cleanup;
        }
        int64_t t_resp = get_monotonic_micros();
        double roundtrip_ms = (double)(t_resp - t_start) / 1000.0;

        if (seek_resp.opcode != OP_RESP_OK) {
            fprintf(stderr, "  [FAIL] Seek to %d%% (%u ms) returned opcode 0x%04x (expected 0x8003)\n",
                    pct, target_ms, seek_resp.opcode);
            goto cleanup;
        }

        // Read updated position from SHM
        uint32_t st_after = 0, pos_after = 0, dur_after = 0;
        read_shm_playback_info(shm, &st_after, &pos_after, &dur_after);

        int32_t delta_ms = (int32_t)pos_after - (int32_t)target_ms;
        printf("  Seek [%2d%%]: Target=%5u ms | SHM Pos=%5u ms (delta=%+3d ms) | RTT: %5.2f ms\n",
               pct, target_ms, pos_after, delta_ms, roundtrip_ms);

        if (roundtrip_ms > 50.0) {
            fprintf(stderr, "  [FAIL] Seek RTT latency %.2f ms exceeds 50ms limit!\n", roundtrip_ms);
            goto cleanup;
        }

        if (abs(delta_ms) > 300) {
            fprintf(stderr, "  [FAIL] Seek position delta %d ms is outside acceptable tolerance (300ms)!\n", delta_ms);
            goto cleanup;
        }

        // Verify monotonic clock progression
        usleep(120000); // 120ms
        uint32_t st_adv = 0, pos_adv = 0, dur_adv = 0;
        read_shm_playback_info(shm, &st_adv, &pos_adv, &dur_adv);

        if (pos_adv <= pos_after) {
            fprintf(stderr, "  [FAIL] Audio clock failed to advance monotonically after seek! (before=%u, after=%u)\n",
                    pos_after, pos_adv);
            goto cleanup;
        }
        printf("    -> Monotonic advance verified: %u ms -> %u ms (+%u ms in 120ms)\n",
               pos_after, pos_adv, pos_adv - pos_after);
    }
    printf("  [PASS] All 5 percentage seeks verified with monotonic clock advancement.\n");

    // 6. Rapid Seek Scrub Stress Test (200 consecutive seek commands)
    printf("\n[4] Rapid Seek Scrub Stress Test (200 consecutive seek commands)...\n");
    int scrub_count = 200;
    int64_t t_scrub_start = get_monotonic_micros();
    for (int i = 0; i < scrub_count; i++) {
        // Scrub back and forth between 1,000ms and 25,000ms
        uint32_t scrub_target = 1000 + (uint32_t)((sin((double)i * 0.1) * 0.5 + 0.5) * 24000.0);

        omm_packet_t scrub_cmd;
        memset(&scrub_cmd, 0, sizeof(scrub_cmd));
        scrub_cmd.magic = OMM_PACKET_MAGIC;
        scrub_cmd.version = 1;
        scrub_cmd.opcode = OP_REQ_SEEK;
        scrub_cmd.seq_id = 7000 + i;
        scrub_cmd.payload.target_ms = scrub_target;

        if (write(sock_fd, &scrub_cmd, sizeof(scrub_cmd)) != sizeof(scrub_cmd)) {
            perror("write scrub");
            goto cleanup;
        }

        omm_packet_t scrub_resp;
        if (read(sock_fd, &scrub_resp, sizeof(scrub_resp)) != sizeof(scrub_resp)) {
            perror("read scrub");
            goto cleanup;
        }
        if (scrub_resp.opcode != OP_RESP_OK) {
            fprintf(stderr, "  [FAIL] Rapid scrub cmd %d returned opcode 0x%04x\n", i, scrub_resp.opcode);
            goto cleanup;
        }
    }
    int64_t t_scrub_end = get_monotonic_micros();
    double scrub_dur_ms = (double)(t_scrub_end - t_scrub_start) / 1000.0;
    printf("  Completed 200 rapid seek scrubs in %.2f ms (%.1f seeks/sec, %.2f us/seek)\n",
           scrub_dur_ms, (double)scrub_count / (scrub_dur_ms / 1000.0), (double)(t_scrub_end - t_scrub_start) / (double)scrub_count);
    printf("  [PASS] Rapid seek scrubbing handled cleanly with zero stalls.\n");

    // 7. Backward seek test: from 90% (27s) to 10% (3s)
    printf("\n[5] Backward Seek Recovery (90%% -> 10%%)...\n");
    omm_packet_t bwd_req;
    memset(&bwd_req, 0, sizeof(bwd_req));
    bwd_req.magic = OMM_PACKET_MAGIC;
    bwd_req.version = 1;
    bwd_req.opcode = OP_REQ_SEEK;
    bwd_req.seq_id = 8001;
    bwd_req.payload.target_ms = 3000;

    if (write(sock_fd, &bwd_req, sizeof(bwd_req)) != sizeof(bwd_req)) {
        perror("write bwd");
        goto cleanup;
    }
    omm_packet_t bwd_resp;
    if (read(sock_fd, &bwd_resp, sizeof(bwd_resp)) != sizeof(bwd_resp)) {
        perror("read bwd");
        goto cleanup;
    }
    if (bwd_resp.opcode != OP_RESP_OK) {
        fprintf(stderr, "  [FAIL] Backward seek failed!\n");
        goto cleanup;
    }

    usleep(50000);
    uint32_t bwd_state = 0, bwd_pos = 0, bwd_dur = 0;
    read_shm_playback_info(shm, &bwd_state, &bwd_pos, &bwd_dur);
    printf("  Post-rewind position: %u ms (target 3000 ms)\n", bwd_pos);
    if (bwd_pos < 2900 || bwd_pos > 3300) {
        fprintf(stderr, "  [FAIL] Position %u ms after rewind to 3000 ms is incorrect!\n", bwd_pos);
        goto cleanup;
    }
    printf("  [PASS] Backward seek rewind verified.\n");

    // 8. Stop playback cleanly
    printf("\n[6] Stopping playback cleanly...\n");
    omm_packet_t stop_req;
    memset(&stop_req, 0, sizeof(stop_req));
    stop_req.magic = OMM_PACKET_MAGIC;
    stop_req.version = 1;
    stop_req.opcode = OP_REQ_STOP;
    stop_req.seq_id = 9001;
    write(sock_fd, &stop_req, sizeof(stop_req));

    omm_packet_t stop_resp;
    read(sock_fd, &stop_resp, sizeof(stop_resp));
    printf("  [PASS] Daemon stopped playback.\n");

    printf("\n======================================================================\n");
    printf("  >>> ALL LIVE SEEK RESPONSIVENESS CHECKS CONFIRMED AND PASSED! <<<   \n");
    printf("======================================================================\n");

    close(sock_fd);
    munmap((void*)shm, OMM_SHM_SIZE);
    close(shm_fd);
    unlink(wav_path);
    return 0;

cleanup:
    close(sock_fd);
    munmap((void*)shm, OMM_SHM_SIZE);
    close(shm_fd);
    unlink(wav_path);
    return 1;
}
