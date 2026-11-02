#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>

#include "omm_abi.h"

#define ASSERT_TRUE(cond, msg, ...) do { \
    if (cond) { \
        printf("  [PASS] " msg "\n", ##__VA_ARGS__); \
    } else { \
        printf("  [FAIL] " msg " (Line %d)\n", ##__VA_ARGS__, __LINE__); \
        return 1; \
    } \
} while(0)

static void generate_wav(const char* path, int duration_ms, int sample_rate, int channels, float freq_hz) {
    FILE* f = fopen(path, "wb");
    if (!f) return;

    int total_samples = (int)((int64_t)duration_ms * sample_rate / 1000);
    int data_bytes = total_samples * channels * 2;
    int riff_size = 36 + data_bytes;
    int byte_rate = sample_rate * channels * 2;
    short block_align = (short)(channels * 2);
    short bits_per_sample = 16;
    short audio_format = 1;

    fwrite("RIFF", 1, 4, f);
    fwrite(&riff_size, 4, 1, f);
    fwrite("WAVEfmt ", 1, 8, f);
    int sub1_size = 16;
    fwrite(&sub1_size, 4, 1, f);
    fwrite(&audio_format, 2, 1, f);
    short ch = (short)channels;
    fwrite(&ch, 2, 1, f);
    fwrite(&sample_rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f);
    fwrite(&block_align, 2, 1, f);
    fwrite(&bits_per_sample, 2, 1, f);
    fwrite("data", 1, 4, f);
    fwrite(&data_bytes, 4, 1, f);

    for (int i = 0; i < total_samples; i++) {
        float t = (float)i / (float)sample_rate;
        short sample = (short)(sinf(2.0f * (float)M_PI * freq_hz * t) * 20000.0f);
        for (int c = 0; c < channels; c++) {
            fwrite(&sample, 2, 1, f);
        }
    }
    fclose(f);
}

typedef struct __attribute__((packed, aligned(512))) {
    uint32_t magic;
    uint32_t version;
    uint32_t record_size;
    uint32_t record_count;
    uint64_t created_timestamp;
    uint64_t last_rescan_timestamp;
    uint8_t reserved[480];
} omm_lib_header_t;

typedef struct __attribute__((packed, aligned(512))) {
    uint32_t track_id;
    uint32_t duration_ms;
    uint16_t year;
    uint16_t track_no;
    uint16_t bitrate_kbps;
    uint16_t format_tag;
    char title[128];
    char artist[96];
    char album[96];
    char relative_path[128];
    int8_t tfidf_vector[32];
    float vector_norm;
    uint8_t reserved[12];
} omm_lib_record_t;

static int create_test_library(const char* lib_path, const char* dir_path) {
    mkdir(dir_path, 0755);

    char p1[256], p2[256], p3[256];
    snprintf(p1, sizeof(p1), "%s/track1.wav", dir_path);
    snprintf(p2, sizeof(p2), "%s/track2.wav", dir_path);
    snprintf(p3, sizeof(p3), "%s/track3.wav", dir_path);

    generate_wav(p1, 500, 48000, 2, 440.0f);
    generate_wav(p2, 700, 48000, 2, 880.0f);
    generate_wav(p3, 600, 48000, 2, 1200.0f);

    FILE* f = fopen(lib_path, "wb");
    if (!f) return -1;

    omm_lib_header_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = OMM_TRACK_MAGIC;
    hdr.version = 1;
    hdr.record_size = 512;
    hdr.record_count = 3;
    hdr.created_timestamp = 1000;
    hdr.last_rescan_timestamp = 1000;
    fwrite(&hdr, 1, sizeof(hdr), f);

    omm_lib_record_t recs[3];
    memset(recs, 0, sizeof(recs));

    recs[0].track_id = 1;
    recs[0].duration_ms = 500;
    recs[0].format_tag = OMM_FORMAT_WAV;
    strncpy(recs[0].title, "Track One", sizeof(recs[0].title) - 1);
    strncpy(recs[0].artist, "Artist Alpha", sizeof(recs[0].artist) - 1);
    strncpy(recs[0].album, "Album One", sizeof(recs[0].album) - 1);
    snprintf(recs[0].relative_path, sizeof(recs[0].relative_path), "%s/track1.wav", dir_path);

    recs[1].track_id = 2;
    recs[1].duration_ms = 700;
    recs[1].format_tag = OMM_FORMAT_WAV;
    strncpy(recs[1].title, "Track Two", sizeof(recs[1].title) - 1);
    strncpy(recs[1].artist, "Artist Beta", sizeof(recs[1].artist) - 1);
    strncpy(recs[1].album, "Album Two", sizeof(recs[1].album) - 1);
    snprintf(recs[1].relative_path, sizeof(recs[1].relative_path), "%s/track2.wav", dir_path);

    recs[2].track_id = 3;
    recs[2].duration_ms = 600;
    recs[2].format_tag = OMM_FORMAT_WAV;
    strncpy(recs[2].title, "Track Three", sizeof(recs[2].title) - 1);
    strncpy(recs[2].artist, "Artist Gamma", sizeof(recs[2].artist) - 1);
    strncpy(recs[2].album, "Album Three", sizeof(recs[2].album) - 1);
    snprintf(recs[2].relative_path, sizeof(recs[2].relative_path), "%s/track3.wav", dir_path);

    fwrite(recs, sizeof(omm_lib_record_t), 3, f);
    fclose(f);
    return 0;
}

static int send_packet(int sock, omm_packet_t* pkt, omm_packet_t* resp) {
    if (write(sock, pkt, sizeof(omm_packet_t)) != sizeof(omm_packet_t)) {
        return -1;
    }
    if (read(sock, resp, sizeof(omm_packet_t)) != sizeof(omm_packet_t)) {
        return -1;
    }
    return 0;
}

static void read_shm_consistent(omm_shm_t* shm_src, omm_shm_t* shm_dst) {
    uint64_t s1, s2;
    do {
        s1 = __atomic_load_n(&shm_src->seqlock, __ATOMIC_ACQUIRE);
        while ((s1 & 1) != 0) {
            #if defined(__x86_64__) || defined(_M_X64)
            __builtin_ia32_pause();
            #endif
            s1 = __atomic_load_n(&shm_src->seqlock, __ATOMIC_ACQUIRE);
        }
        __builtin_ia32_lfence();
        memcpy(shm_dst, shm_src, sizeof(omm_shm_t));
        __builtin_ia32_lfence();
        s2 = __atomic_load_n(&shm_src->seqlock, __ATOMIC_ACQUIRE);
    } while (s1 != s2);
}

int main(void) {
    printf("======================================================================\n");
    printf("   Daemon Multi-Track Autonomous Gapless & Metadata Challenge        \n");
    printf("======================================================================\n");

    const char* test_dir = "/tmp/omm_gapless_test";
    const char* lib_path = "/tmp/omm_gapless_test/library.bin";
    const char* sock_path = "/tmp/omm_gapless_test/omm.sock";
    const char* shm_path = "/tmp/omm_gapless_test/omm_shm";

    unlink(sock_path);
    unlink(shm_path);

    if (create_test_library(lib_path, test_dir) != 0) {
        fprintf(stderr, "Failed to create synthetic test library\n");
        return 1;
    }

    /* Spawn daemon */
    pid_t pid = fork();
    if (pid == 0) {
        execl("./bin/omm_daemon", "./bin/omm_daemon",
              "--socket", sock_path,
              "--shm", shm_path,
              "--music-dir", test_dir,
              "--library", lib_path,
              (char*)NULL);
        exit(127);
    }

    printf("  [INFO] Spawned omm_daemon child process (PID=%d)...\n", pid);

    /* Wait for socket & SHM to become available */
    int sock = -1;
    for (int retry = 0; retry < 50; retry++) {
        usleep(50000); // 50ms
        sock = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
        if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
            break;
        }
        close(sock);
        sock = -1;
    }
    ASSERT_TRUE(sock >= 0, "Connected to daemon UDS socket");

    int shm_fd = open(shm_path, O_RDWR);
    ASSERT_TRUE(shm_fd >= 0, "Opened daemon shared memory file");
    omm_shm_t* shm = (omm_shm_t*)mmap(NULL, sizeof(omm_shm_t), PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
    ASSERT_TRUE(shm != MAP_FAILED, "Mmapped daemon shared memory");

    omm_shm_t snap;
    read_shm_consistent(shm, &snap);
    ASSERT_TRUE(snap.magic == OMM_SHM_MAGIC, "SHM magic is OMMS");

    /* Send PLAY_TRACK_ID = 1 */
    omm_packet_t pkt, resp;
    memset(&pkt, 0, sizeof(pkt));
    pkt.magic = OMM_PACKET_MAGIC;
    pkt.version = 1;
    pkt.opcode = OP_REQ_PLAY_TRACK_ID;
    pkt.seq_id = 1;
    pkt.payload.track_id = 1;

    int rc = send_packet(sock, &pkt, &resp);
    ASSERT_TRUE(rc == 0 && resp.status_code == OMM_OK, "Sent OP_REQ_PLAY_TRACK_ID (1) successfully");

    /* Verify initial playback of Track 1 */
    usleep(100000); // 100ms
    read_shm_consistent(shm, &snap);
    ASSERT_TRUE(snap.playback_state == OMM_STATE_PLAYING, "Daemon playback state is PLAYING");
    ASSERT_TRUE(snap.current_track_id == 1, "SHM current_track_id is 1 (actual %u)", snap.current_track_id);
    ASSERT_TRUE(strcmp(snap.track_title, "Track One") == 0, "SHM track_title is 'Track One' (actual '%s')", snap.track_title);
    ASSERT_TRUE(snap.duration_ms == 500, "SHM duration_ms is 500 ms (actual %u)", snap.duration_ms);

    /* Monitor progression: Track 1 (500ms) enters prefetch zone at pos >= 250ms */
    printf("  [INFO] Waiting for Track 1 autonomous prefetch trigger (dur=500ms, threshold=250ms)...\n");
    bool prefetch_seen_t1 = false;
    for (int i = 0; i < 10; i++) {
        usleep(40000); // 40ms polling
        read_shm_consistent(shm, &snap);
        if ((snap.playback_flags & OMM_FLAG_PREFETCHING) != 0) {
            prefetch_seen_t1 = true;
            break;
        }
    }
    ASSERT_TRUE(prefetch_seen_t1, "OMM_FLAG_PREFETCHING autonomously asserted by daemon for Track 2");

    /* Wait for Track 1 completion and autonomous transition to Track 2 */
    printf("  [INFO] Waiting for Track 1 completion and autonomous transition to Track 2...\n");
    bool transitioned_t2 = false;
    for (int i = 0; i < 20; i++) {
        usleep(40000); // 40ms polling
        read_shm_consistent(shm, &snap);
        if (snap.current_track_id == 2) {
            transitioned_t2 = true;
            break;
        }
    }
    ASSERT_TRUE(transitioned_t2, "Autonomous decoder swap to Track 2 occurred");
    ASSERT_TRUE(strcmp(snap.track_title, "Track Two") == 0, "SHM track_title updated to 'Track Two' (actual '%s')", snap.track_title);
    ASSERT_TRUE(strcmp(snap.track_artist, "Artist Beta") == 0, "SHM track_artist updated to 'Artist Beta' (actual '%s')", snap.track_artist);
    ASSERT_TRUE(snap.duration_ms == 700, "SHM duration_ms updated to 700 ms (actual %u)", snap.duration_ms);
    ASSERT_TRUE(snap.position_ms < 700, "SHM position_ms reset and < 700 ms (actual %u)", snap.position_ms);

    /* Now verify prefetch of Track 3 occurs! (Proves TOmmRouter.FPrefetchActive was cleared) */
    printf("  [INFO] Waiting for Track 2 autonomous prefetch trigger for Track 3 (dur=700ms, threshold=350ms)...\n");
    bool prefetch_seen_t2 = false;
    for (int i = 0; i < 20; i++) {
        usleep(40000);
        read_shm_consistent(shm, &snap);
        if ((snap.playback_flags & OMM_FLAG_PREFETCHING) != 0) {
            prefetch_seen_t2 = true;
            break;
        }
    }
    ASSERT_TRUE(prefetch_seen_t2, "OMM_FLAG_PREFETCHING asserted for Track 3 (autonomous chain progression VERIFIED)");

    /* Wait for Track 2 completion and transition to Track 3 */
    printf("  [INFO] Waiting for Track 2 completion and transition to Track 3...\n");
    bool transitioned_t3 = false;
    for (int i = 0; i < 25; i++) {
        usleep(40000);
        read_shm_consistent(shm, &snap);
        if (snap.current_track_id == 3) {
            transitioned_t3 = true;
            break;
        }
    }
    ASSERT_TRUE(transitioned_t3, "Autonomous decoder swap to Track 3 occurred");
    ASSERT_TRUE(strcmp(snap.track_title, "Track Three") == 0, "SHM track_title updated to 'Track Three' (actual '%s')", snap.track_title);
    ASSERT_TRUE(snap.duration_ms == 600, "SHM duration_ms updated to 600 ms (actual %u)", snap.duration_ms);

    /* Cleanup */
    close(sock);
    munmap(shm, sizeof(omm_shm_t));
    close(shm_fd);

    kill(pid, SIGTERM);
    waitpid(pid, NULL, 0);

    unlink(sock_path);
    unlink(shm_path);
    unlink(lib_path);
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s/track1.wav", test_dir); unlink(tmp);
    snprintf(tmp, sizeof(tmp), "%s/track2.wav", test_dir); unlink(tmp);
    snprintf(tmp, sizeof(tmp), "%s/track3.wav", test_dir); unlink(tmp);
    rmdir(test_dir);

    printf("\n>>> VERDICT: LIVE DAEMON GAPLESS AUTONOMOUS CHAINING CONFIRMED <<<\n");
    return 0;
}
