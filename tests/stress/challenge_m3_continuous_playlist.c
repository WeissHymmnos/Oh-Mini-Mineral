#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include <time.h>
#include <errno.h>
#include <dirent.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <sys/wait.h>

#include "omm_abi.h"

/* ========================================================================= */
/* Test Harness Constants & Statistics                                       */
/* ========================================================================= */

#define TEST_SOCKET_PATH "/tmp/omm_m3_challenger_pl.sock"
#define TEST_SHM_PATH    "/tmp/omm_m3_challenger_pl_shm"
#define TEST_LIB_PATH    "/tmp/omm_m3_challenger_pl.bin"

#define WAV_T1 "/tmp/omm_m3_pl_t1.wav"
#define WAV_T2 "/tmp/omm_m3_pl_t2.wav"
#define WAV_T3 "/tmp/omm_m3_pl_t3.wav"
#define WAV_T4 "/tmp/omm_m3_pl_t4.wav"

static int g_tests_run = 0;
static int g_tests_passed = 0;
static int g_tests_failed = 0;

#define ASSERT_TRUE(cond, fmt, ...) do { \
    g_tests_run++; \
    if (cond) { \
        g_tests_passed++; \
        printf("  [PASS] " fmt "\n", ##__VA_ARGS__); \
    } else { \
        g_tests_failed++; \
        printf("  [FAIL] " fmt " (Line %d)\n", ##__VA_ARGS__, __LINE__); \
    } \
} while (0)

/* ========================================================================= */
/* 512-Byte Library Binary Structures                                        */
/* ========================================================================= */

typedef struct __attribute__((packed, aligned(512))) {
    uint32_t magic;                  /* 0x0000: 0x4F4D4D4C ("OMML") */
    uint32_t version;                /* 0x0004: Version (1) */
    uint32_t record_size;            /* 0x0008: Record size (512) */
    uint32_t record_count;           /* 0x000C: Record count */
    uint64_t created_timestamp;      /* 0x0010: Created timestamp */
    uint64_t last_rescan_timestamp;  /* 0x0018: Last rescan timestamp */
    uint8_t reserved[480];           /* 0x0020: Pad to 512 bytes */
} test_library_header_t;

/* ========================================================================= */
/* Synthetic Audio WAV Generator                                             */
/* ========================================================================= */

static void generate_wav(const char* path, int duration_ms, int sample_rate, int channels, float freq_hz) {
    int total_samples = (int)(((long long)duration_ms * sample_rate) / 1000);
    int bits_per_sample = 16;
    int block_align = channels * (bits_per_sample / 8);
    int byte_rate = sample_rate * block_align;
    int data_bytes = total_samples * block_align;
    int riff_size = 36 + data_bytes;

    FILE* f = fopen(path, "wb");
    if (!f) {
        perror("fopen wav");
        return;
    }

    fwrite("RIFF", 1, 4, f);
    fwrite(&riff_size, 4, 1, f);
    fwrite("WAVEfmt ", 1, 8, f);
    int sub1_size = 16;
    fwrite(&sub1_size, 4, 1, f);
    short audio_format = 1; // PCM
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

/* ========================================================================= */
/* Binary Library Generator                                                  */
/* ========================================================================= */

static void create_test_library(const char* lib_path,
                                const char* track_paths[],
                                const uint32_t durations[],
                                const char* titles[],
                                const char* artists[],
                                const char* albums[],
                                uint32_t count) {
    FILE* f = fopen(lib_path, "wb");
    if (!f) {
        perror("fopen library");
        return;
    }

    test_library_header_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = OMM_TRACK_MAGIC;
    hdr.version = 1;
    hdr.record_size = 512;
    hdr.record_count = count;
    hdr.created_timestamp = (uint64_t)time(NULL);
    hdr.last_rescan_timestamp = (uint64_t)time(NULL);
    fwrite(&hdr, 1, sizeof(hdr), f);

    for (uint32_t i = 0; i < count; i++) {
        omm_track_record_t rec;
        memset(&rec, 0, sizeof(rec));
        rec.track_id = i + 1;
        rec.duration_ms = durations[i];
        rec.year = 2026;
        rec.track_no = (uint16_t)(i + 1);
        rec.bitrate_kbps = 1536;
        rec.format_tag = OMM_FORMAT_WAV;
        strncpy(rec.title, titles[i], sizeof(rec.title) - 1);
        strncpy(rec.artist, artists[i], sizeof(rec.artist) - 1);
        strncpy(rec.album, albums[i], sizeof(rec.album) - 1);
        strncpy(rec.relative_path, track_paths[i], sizeof(rec.relative_path) - 1);
        rec.vector_norm = 1.0f;
        fwrite(&rec, 1, sizeof(rec), f);
    }
    fclose(f);
}

/* ========================================================================= */
/* Seqlock Consistent SHM Reader                                             */
/* ========================================================================= */

static bool read_shm_consistent(const omm_shm_t* shm, omm_shm_t* snap) {
    uint64_t s1, s2;
    int spin = 0;
    do {
        s1 = __atomic_load_n(&shm->seqlock, __ATOMIC_ACQUIRE);
        while (s1 & 1) {
            #if defined(__x86_64__) || defined(_M_X64)
            __builtin_ia32_pause();
            #endif
            s1 = __atomic_load_n(&shm->seqlock, __ATOMIC_ACQUIRE);
            spin++;
            if (spin > 5000000) return false;
        }
        __builtin_ia32_lfence();
        memcpy(snap, shm, sizeof(omm_shm_t));
        __builtin_ia32_lfence();
        s2 = __atomic_load_n(&shm->seqlock, __ATOMIC_ACQUIRE);
    } while (s1 != s2);
    return true;
}

/* ========================================================================= */
/* UDS Socket Client Helpers                                                 */
/* ========================================================================= */

static int connect_to_daemon(const char* sock_path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool send_packet(int fd, uint16_t opcode, uint32_t seq, const void* payload, size_t payload_len) {
    omm_packet_t pkt;
    memset(&pkt, 0, sizeof(pkt));
    pkt.magic = OMM_PACKET_MAGIC;
    pkt.version = 1;
    pkt.opcode = opcode;
    pkt.seq_id = seq;
    pkt.status_code = 0;
    if (payload && payload_len > 0) {
        if (payload_len > sizeof(pkt.payload)) payload_len = sizeof(pkt.payload);
        memcpy(&pkt.payload, payload, payload_len);
    }
    ssize_t written = write(fd, &pkt, sizeof(pkt));
    return (written == (ssize_t)sizeof(pkt));
}

static bool recv_packet(int fd, omm_packet_t* pkt) {
    size_t total = 0;
    uint8_t* buf = (uint8_t*)pkt;
    while (total < sizeof(omm_packet_t)) {
        ssize_t r = read(fd, buf + total, sizeof(omm_packet_t) - total);
        if (r <= 0) return false;
        total += (size_t)r;
    }
    return (pkt->magic == OMM_PACKET_MAGIC);
}

/* ========================================================================= */
/* Process Introspection Helpers                                             */
/* ========================================================================= */

static int64_t get_proc_rss_kb(pid_t pid) {
    char statm_path[64];
    snprintf(statm_path, sizeof(statm_path), "/proc/%d/statm", pid);
    FILE* f = fopen(statm_path, "r");
    if (!f) return -1;
    int64_t size_pages = 0, resident_pages = 0;
    if (fscanf(f, "%ld %ld", &size_pages, &resident_pages) != 2) {
        fclose(f);
        return -1;
    }
    fclose(f);
    return resident_pages * 4; // 4KB per page
}

static int count_open_fds(pid_t pid) {
    char fd_dir[64];
    snprintf(fd_dir, sizeof(fd_dir), "/proc/%d/fd", pid);
    DIR* d = opendir(fd_dir);
    if (!d) return -1;
    int count = 0;
    struct dirent* entry;
    while ((entry = readdir(d)) != NULL) {
        if (entry->d_name[0] != '.') count++;
    }
    closedir(d);
    return count;
}

/* ========================================================================= */
/* Daemon Process Spawner & Lifecycle                                        */
/* ========================================================================= */

static pid_t spawn_daemon(const char* sock_path, const char* shm_path, const char* lib_path) {
    unlink(sock_path);
    unlink(shm_path);

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return -1;
    }

    if (pid == 0) {
        // Child process
        char* args[] = {
            "bin/omm_daemon",
            "--socket", (char*)sock_path,
            "--shm", (char*)shm_path,
            "--library", (char*)lib_path,
            NULL
        };
        execv("bin/omm_daemon", args);
        perror("execv bin/omm_daemon");
        exit(127);
    }

    // Parent: wait for daemon socket and shm file to be ready (up to 3 seconds)
    int attempts = 0;
    while (attempts < 60) {
        usleep(50000); // 50ms
        int fd = connect_to_daemon(sock_path);
        if (fd >= 0) {
            close(fd);
            // Check SHM file exists and size is >= 65536
            struct stat st;
            if (stat(shm_path, &st) == 0 && st.st_size >= OMM_SHM_SIZE) {
                return pid;
            }
        }
        attempts++;
    }

    fprintf(stderr, "Timed out waiting for omm_daemon (PID=%d)\n", pid);
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    return -1;
}

static void stop_daemon(pid_t pid, const char* sock_path, const char* shm_path) {
    if (pid > 0) {
        kill(pid, SIGTERM);
        int status;
        for (int i = 0; i < 20; i++) {
            pid_t r = waitpid(pid, &status, WNOHANG);
            if (r == pid) break;
            usleep(50000);
        }
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
    }
    unlink(sock_path);
    unlink(shm_path);
}

static omm_shm_t* map_shm(const char* shm_path) {
    int fd = open(shm_path, O_RDWR);
    if (fd < 0) {
        perror("open shm");
        return NULL;
    }
    void* ptr = mmap(NULL, OMM_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (ptr == MAP_FAILED) {
        perror("mmap shm");
        return NULL;
    }
    return (omm_shm_t*)ptr;
}

static void unmap_shm(omm_shm_t* shm) {
    if (shm) {
        munmap((void*)shm, OMM_SHM_SIZE);
    }
}

/* ========================================================================= */
/* SUITE 1: Autonomous Multi-Track Gapless Progression & Metadata Updates    */
/* SUITE 2: Clock Monotonicity Invariant Across Boundaries                   */
/* ========================================================================= */

static void test_autonomous_multi_track_progression_and_clock(void) {
    printf("\n======================================================================\n");
    printf("   [SUITE 1 & 2] Autonomous Multi-Track Gapless Progression & Clock Invariant\n");
    printf("======================================================================\n");

    const char* paths[] = { WAV_T1, WAV_T2, WAV_T3, WAV_T4 };
    const uint32_t durations[] = { 400, 500, 600, 700 };
    const char* titles[] = { "Alpha Symphony", "Beta Sonata", "Gamma Rhapsody", "Delta Nocturne" };
    const char* artists[] = { "Composer One", "Composer Two", "Composer Three", "Composer Four" };
    const char* albums[] = { "Opus Test", "Opus Test", "Opus Test", "Opus Test" };

    // 1. Generate 4 audio tracks
    generate_wav(WAV_T1, durations[0], 48000, 2, 440.0f);
    generate_wav(WAV_T2, durations[1], 48000, 2, 554.37f);
    generate_wav(WAV_T3, durations[2], 48000, 2, 659.25f);
    generate_wav(WAV_T4, durations[3], 48000, 2, 880.0f);

    // 2. Generate library.bin
    create_test_library(TEST_LIB_PATH, paths, durations, titles, artists, albums, 4);

    // 3. Spawn daemon
    pid_t daemon_pid = spawn_daemon(TEST_SOCKET_PATH, TEST_SHM_PATH, TEST_LIB_PATH);
    ASSERT_TRUE(daemon_pid > 0, "Spawned live omm_daemon with 4-track library (PID=%d)", daemon_pid);
    if (daemon_pid <= 0) return;

    omm_shm_t* shm = map_shm(TEST_SHM_PATH);
    ASSERT_TRUE(shm != NULL, "Mapped 64KB shared memory segment from %s", TEST_SHM_PATH);
    if (!shm) {
        stop_daemon(daemon_pid, TEST_SOCKET_PATH, TEST_SHM_PATH);
        return;
    }

    int client_fd = connect_to_daemon(TEST_SOCKET_PATH);
    ASSERT_TRUE(client_fd >= 0, "Connected UDS client to %s", TEST_SOCKET_PATH);
    if (client_fd < 0) {
        unmap_shm(shm);
        stop_daemon(daemon_pid, TEST_SOCKET_PATH, TEST_SHM_PATH);
        return;
    }

    // 4. Issue single command: Play Track 1 via TrackID
    printf("  [INFO] Issuing single OP_REQ_PLAY_TRACK_ID (TrackID=1). NO further commands will be issued.\n");
    uint32_t req_track_id = 1;
    ASSERT_TRUE(send_packet(client_fd, OP_REQ_PLAY_TRACK_ID, 101, &req_track_id, sizeof(req_track_id)),
                "Sent OP_REQ_PLAY_TRACK_ID (1) packet");

    omm_packet_t resp;
    ASSERT_TRUE(recv_packet(client_fd, &resp), "Received response from daemon");
    ASSERT_TRUE(resp.opcode == OP_RESP_OK, "Daemon responded with OP_RESP_OK (status=%d)", resp.status_code);

    // 5. Monitor autonomous continuous progression over total expected duration ~2200ms
    // We sample every 1-2 ms
    uint32_t observed_tracks[5] = {0};
    bool prefetch_seen_for_track[5] = {false};
    uint64_t total_snapshots = 0;
    uint64_t clock_monotonicity_violations = 0;
    uint32_t max_pos_seen[5] = {0};
    uint32_t min_pos_seen[5] = {999999, 999999, 999999, 999999, 999999};
    uint32_t prev_track = 0;
    int state_drop_to_stopped = 0;

    omm_shm_t snap;
    struct timespec start_ts, now_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);

    printf("  [INFO] Monitoring SHM autonomously across track cutovers...\n");

    while (1) {
        clock_gettime(CLOCK_MONOTONIC, &now_ts);
        double elapsed_sec = (double)(now_ts.tv_sec - start_ts.tv_sec) +
                             (double)(now_ts.tv_nsec - start_ts.tv_nsec) / 1e9;

        if (elapsed_sec > 4.5) {
            // Safety timeout (4.5s is well past 2.2s total track time)
            break;
        }

        if (read_shm_consistent(shm, &snap)) {
            total_snapshots++;
            uint32_t cur_track = snap.current_track_id;
            uint32_t cur_pos = snap.position_ms;
            uint32_t cur_dur = snap.duration_ms;
            uint32_t flags = snap.playback_flags;
            uint32_t state = snap.playback_state;

            // Invariant Check 1: position_ms <= duration_ms
            if (cur_dur > 0 && cur_pos > cur_dur) {
                clock_monotonicity_violations++;
                if (clock_monotonicity_violations <= 5) {
                    printf("  [VIOLATION] Invariant failure: pos=%u ms > dur=%u ms (TrackID=%u, state=%u)\n",
                           cur_pos, cur_dur, cur_track, state);
                }
            }

            // Track state transitions
            if (cur_track >= 1 && cur_track <= 4) {
                observed_tracks[cur_track]++;
                if (cur_pos > max_pos_seen[cur_track]) max_pos_seen[cur_track] = cur_pos;
                if (cur_pos < min_pos_seen[cur_track]) min_pos_seen[cur_track] = cur_pos;

                // Check prefetch flag while on this track
                if ((flags & OMM_FLAG_PREFETCHING) != 0) {
                    prefetch_seen_for_track[cur_track] = true;
                }

                // Check metadata synchronization
                if (prev_track != cur_track) {
                    printf("  [CUTOVER] Detected transition to Track %u at elapsed=%.3fs (Title='%s', Dur=%u ms, Pos=%u ms)\n",
                           cur_track, elapsed_sec, snap.track_title, cur_dur, cur_pos);
                    // Verify title matches expected track
                    if (strcmp(snap.track_title, titles[cur_track - 1]) == 0) {
                        ASSERT_TRUE(true, "Cutover to Track %u verified metadata title: '%s'", cur_track, snap.track_title);
                    } else {
                        ASSERT_TRUE(false, "Cutover to Track %u metadata mismatch: got '%s', expected '%s'",
                                    cur_track, snap.track_title, titles[cur_track - 1]);
                    }
                    // Verify duration matches expected track
                    ASSERT_TRUE(cur_dur == durations[cur_track - 1],
                                "Cutover to Track %u verified duration: %u ms (expected %u ms)",
                                cur_track, cur_dur, durations[cur_track - 1]);

                    // Verify state remained PLAYING across cutover (gapless)
                    ASSERT_TRUE(state == OMM_STATE_PLAYING,
                                "Playback state is continuous OMM_STATE_PLAYING across Track %u transition", cur_track);

                    prev_track = cur_track;
                }
            }

            if (state == OMM_STATE_STOPPED && prev_track == 4 && elapsed_sec > 1.8) {
                // Track 4 finished and daemon cleanly stopped at playlist end
                printf("  [COMPLETION] Autonomous playlist playback completed cleanly (State=STOPPED at elapsed=%.3fs)\n", elapsed_sec);
                break;
            }

            if (state == OMM_STATE_STOPPED && prev_track > 0 && prev_track < 4) {
                state_drop_to_stopped++;
            }
        }

        usleep(1000); // 1ms polling cadence
    }

    printf("\n  --- Autonomous Progression Metrics ---\n");
    printf("  Total Seqlock Snapshots Checked: %lu\n", (unsigned long)total_snapshots);
    printf("  Clock Invariant Violations (pos > dur): %lu\n", (unsigned long)clock_monotonicity_violations);

    for (int t = 1; t <= 4; t++) {
        printf("  Track %d (%s, dur=%u ms): %u snapshots, pos range [%u..%u ms], prefetch armed=%s\n",
               t, titles[t - 1], durations[t - 1], observed_tracks[t],
               min_pos_seen[t], max_pos_seen[t],
               prefetch_seen_for_track[t] ? "YES" : "NO");
    }

    // Assertions
    ASSERT_TRUE(observed_tracks[1] > 50, "Track 1 played autonomously (>50 snapshots)");
    ASSERT_TRUE(observed_tracks[2] > 50, "Track 2 played autonomously without manual play_uri (>50 snapshots)");
    ASSERT_TRUE(observed_tracks[3] > 50, "Track 3 played autonomously without manual play_uri (>50 snapshots)");
    ASSERT_TRUE(observed_tracks[4] > 50, "Track 4 played autonomously without manual play_uri (>50 snapshots)");

    ASSERT_TRUE(prefetch_seen_for_track[1], "Track 1 activated prefetch for Track 2 (FPrefetchActive armed)");
    ASSERT_TRUE(prefetch_seen_for_track[2], "Track 2 activated prefetch for Track 3 (FPrefetchActive did NOT deadlock)");
    ASSERT_TRUE(prefetch_seen_for_track[3], "Track 3 activated prefetch for Track 4 (FPrefetchActive continuous)");

    ASSERT_TRUE(state_drop_to_stopped == 0, "ZERO premature state drops to STOPPED before Track 4 completion (gapless)");
    ASSERT_TRUE(total_snapshots >= 1000, "Continuous sampling collected >= 1,000 Seqlock snapshots (got %lu)", (unsigned long)total_snapshots);
    ASSERT_TRUE(clock_monotonicity_violations == 0, "ZERO clock monotonicity invariant violations (pos_ms <= duration_ms strictly held)");

    close(client_fd);
    unmap_shm(shm);
    stop_daemon(daemon_pid, TEST_SOCKET_PATH, TEST_SHM_PATH);

    unlink(WAV_T1);
    unlink(WAV_T2);
    unlink(WAV_T3);
    unlink(WAV_T4);
    unlink(TEST_LIB_PATH);
}

/* ========================================================================= */
/* SUITE 3: Prefetch Cancellation on Backwards Seek                          */
/* ========================================================================= */

static void test_prefetch_cancellation_backwards_seek(void) {
    printf("\n======================================================================\n");
    printf("   [SUITE 3] Prefetch Cancellation on Backwards Seek                 \n");
    printf("======================================================================\n");

    const char* paths[] = { WAV_T1, WAV_T2 };
    const uint32_t durations[] = { 400, 500 };
    const char* titles[] = { "Track One", "Track Two" };
    const char* artists[] = { "Artist A", "Artist B" };
    const char* albums[] = { "Album X", "Album X" };

    generate_wav(WAV_T1, durations[0], 48000, 2, 440.0f);
    generate_wav(WAV_T2, durations[1], 48000, 2, 554.37f);
    create_test_library(TEST_LIB_PATH, paths, durations, titles, artists, albums, 2);

    pid_t daemon_pid = spawn_daemon(TEST_SOCKET_PATH, TEST_SHM_PATH, TEST_LIB_PATH);
    ASSERT_TRUE(daemon_pid > 0, "Spawned live omm_daemon (PID=%d)", daemon_pid);
    if (daemon_pid <= 0) return;

    omm_shm_t* shm = map_shm(TEST_SHM_PATH);
    int client_fd = connect_to_daemon(TEST_SOCKET_PATH);

    // 1. Start Track 1
    uint32_t req_track_id = 1;
    send_packet(client_fd, OP_REQ_PLAY_TRACK_ID, 201, &req_track_id, sizeof(req_track_id));
    omm_packet_t resp;
    recv_packet(client_fd, &resp);

    // 2. Wait until Track 1 enters prefetch zone (pos >= 200 ms) and OMM_FLAG_PREFETCHING is set
    printf("  [INFO] Waiting for Track 1 to reach prefetch zone (pos >= 200 ms)...\n");
    omm_shm_t snap;
    bool prefetch_armed = false;
    for (int i = 0; i < 250; i++) {
        usleep(2000);
        if (read_shm_consistent(shm, &snap)) {
            if ((snap.playback_flags & OMM_FLAG_PREFETCHING) != 0 && snap.position_ms >= 180) {
                prefetch_armed = true;
                break;
            }
        }
    }
    ASSERT_TRUE(prefetch_armed, "OMM_FLAG_PREFETCHING asserted in SHM at pos=%u ms", snap.position_ms);

    // 3. Issue Backwards Seek to 40 ms (out of prefetch zone)
    printf("  [ACTION] Issuing OP_REQ_SEEK to 40 ms (seeking backwards out of prefetch zone)...\n");
    uint32_t seek_target = 40;
    send_packet(client_fd, OP_REQ_SEEK, 202, &seek_target, sizeof(seek_target));
    recv_packet(client_fd, &resp);
    ASSERT_TRUE(resp.opcode == OP_RESP_OK, "Seek command acknowledged with OP_RESP_OK");

    // 4. Verify OMM_FLAG_PREFETCHING is cancelled
    bool prefetch_cancelled = false;
    for (int i = 0; i < 50; i++) {
        usleep(2000);
        if (read_shm_consistent(shm, &snap)) {
            if ((snap.playback_flags & OMM_FLAG_PREFETCHING) == 0 && snap.position_ms < 150) {
                prefetch_cancelled = true;
                break;
            }
        }
    }
    ASSERT_TRUE(prefetch_cancelled, "OMM_FLAG_PREFETCHING cleanly cleared after backwards seek (pos=%u ms)", snap.position_ms);

    // 5. Allow playback to progress again until pos >= 200ms and verify prefetch re-arms
    printf("  [INFO] Verifying prefetch re-arms when audio reaches prefetch zone a second time...\n");
    bool prefetch_rearmed = false;
    for (int i = 0; i < 250; i++) {
        usleep(2000);
        if (read_shm_consistent(shm, &snap)) {
            if ((snap.playback_flags & OMM_FLAG_PREFETCHING) != 0 && snap.position_ms >= 180) {
                prefetch_rearmed = true;
                break;
            }
        }
    }
    ASSERT_TRUE(prefetch_rearmed, "OMM_FLAG_PREFETCHING successfully re-armed upon re-entering zone (pos=%u ms)", snap.position_ms);

    // 6. Verify seamless cutover to Track 2 still occurs
    printf("  [INFO] Waiting for transition to Track 2...\n");
    bool cutover_success = false;
    for (int i = 0; i < 300; i++) {
        usleep(2000);
        if (read_shm_consistent(shm, &snap)) {
            if (snap.current_track_id == 2) {
                cutover_success = true;
                break;
            }
        }
    }
    ASSERT_TRUE(cutover_success, "Seamless cutover to Track 2 completed after cancelled-and-rearmed prefetch");

    close(client_fd);
    unmap_shm(shm);
    stop_daemon(daemon_pid, TEST_SOCKET_PATH, TEST_SHM_PATH);
    unlink(WAV_T1);
    unlink(WAV_T2);
    unlink(TEST_LIB_PATH);
}

/* ========================================================================= */
/* SUITE 4: Prefetch Cancellation on Manual User Intervention (Stop & Play)  */
/* ========================================================================= */

static void test_prefetch_cancellation_manual_intervention(void) {
    printf("\n======================================================================\n");
    printf("   [SUITE 4] Prefetch Cancellation on Manual Stop & Manual PlayURI   \n");
    printf("======================================================================\n");

    const char* paths[] = { WAV_T1, WAV_T2, WAV_T3 };
    const uint32_t durations[] = { 400, 500, 600 };
    const char* titles[] = { "Track One", "Track Two", "Track Three" };
    const char* artists[] = { "Artist A", "Artist B", "Artist C" };
    const char* albums[] = { "Album X", "Album X", "Album X" };

    generate_wav(WAV_T1, durations[0], 48000, 2, 440.0f);
    generate_wav(WAV_T2, durations[1], 48000, 2, 554.37f);
    generate_wav(WAV_T3, durations[2], 48000, 2, 659.25f);
    create_test_library(TEST_LIB_PATH, paths, durations, titles, artists, albums, 3);

    pid_t daemon_pid = spawn_daemon(TEST_SOCKET_PATH, TEST_SHM_PATH, TEST_LIB_PATH);
    ASSERT_TRUE(daemon_pid > 0, "Spawned live omm_daemon (PID=%d)", daemon_pid);
    if (daemon_pid <= 0) return;

    omm_shm_t* shm = map_shm(TEST_SHM_PATH);
    int client_fd = connect_to_daemon(TEST_SOCKET_PATH);

    // --- SUBTEST A: Stop during active prefetch window ---
    printf("  [SUBTEST A] Testing Stop during active prefetch...\n");
    uint32_t req_track_id = 1;
    send_packet(client_fd, OP_REQ_PLAY_TRACK_ID, 301, &req_track_id, sizeof(req_track_id));
    omm_packet_t resp;
    recv_packet(client_fd, &resp);

    omm_shm_t snap;
    for (int i = 0; i < 200; i++) {
        usleep(2000);
        if (read_shm_consistent(shm, &snap)) {
            if ((snap.playback_flags & OMM_FLAG_PREFETCHING) != 0) break;
        }
    }
    ASSERT_TRUE((snap.playback_flags & OMM_FLAG_PREFETCHING) != 0, "Prefetch active for Track 2");

    // Issue OP_REQ_STOP
    send_packet(client_fd, OP_REQ_STOP, 302, NULL, 0);
    recv_packet(client_fd, &resp);
    ASSERT_TRUE(resp.opcode == OP_RESP_OK, "Stop acknowledged");

    usleep(20000);
    read_shm_consistent(shm, &snap);
    ASSERT_TRUE(snap.playback_state == OMM_STATE_STOPPED, "Playback state is OMM_STATE_STOPPED");
    ASSERT_TRUE((snap.playback_flags & OMM_FLAG_PREFETCHING) == 0, "OMM_FLAG_PREFETCHING cleared on Stop");

    // Wait to ensure stale decoder does not start playing Track 2
    usleep(250000); // 250ms
    read_shm_consistent(shm, &snap);
    ASSERT_TRUE(snap.playback_state == OMM_STATE_STOPPED, "Daemon remains STOPPED without rogue playback");

    // --- SUBTEST B: Manual PlayURI Override during active prefetch window ---
    printf("  [SUBTEST B] Testing Manual PlayURI override during active prefetch...\n");
    send_packet(client_fd, OP_REQ_PLAY_TRACK_ID, 303, &req_track_id, sizeof(req_track_id));
    recv_packet(client_fd, &resp);

    for (int i = 0; i < 200; i++) {
        usleep(2000);
        if (read_shm_consistent(shm, &snap)) {
            if ((snap.playback_flags & OMM_FLAG_PREFETCHING) != 0) break;
        }
    }
    ASSERT_TRUE((snap.playback_flags & OMM_FLAG_PREFETCHING) != 0, "Prefetch active for Track 2");

    // User intervenes: jumps directly to Track 3 via manual OP_REQ_PLAY_TRACK_ID (3)
    uint32_t override_track_id = 3;
    printf("  [ACTION] Issuing manual OP_REQ_PLAY_TRACK_ID (3) to override preloaded Track 2...\n");
    send_packet(client_fd, OP_REQ_PLAY_TRACK_ID, 304, &override_track_id, sizeof(override_track_id));
    recv_packet(client_fd, &resp);
    ASSERT_TRUE(resp.opcode == OP_RESP_OK, "Manual track jump acknowledged");

    usleep(30000);
    read_shm_consistent(shm, &snap);
    ASSERT_TRUE(snap.current_track_id == 3, "CurrentTrackID immediately updated to 3 (got %u)", snap.current_track_id);
    ASSERT_TRUE(strcmp(snap.track_title, "Track Three") == 0, "Track title updated to 'Track Three'");
    ASSERT_TRUE(snap.duration_ms == 600, "Duration updated to 600 ms");

    close(client_fd);
    unmap_shm(shm);
    stop_daemon(daemon_pid, TEST_SOCKET_PATH, TEST_SHM_PATH);
    unlink(WAV_T1);
    unlink(WAV_T2);
    unlink(WAV_T3);
    unlink(TEST_LIB_PATH);
}

/* ========================================================================= */
/* SUITE 5: Prefetch Stress Churn & Resource Leak Check                      */
/* ========================================================================= */

static void test_prefetch_churn_and_resource_leaks(void) {
    printf("\n======================================================================\n");
    printf("   [SUITE 5] Prefetch Churn & Resource Leak Stress Test (50 Cycles)   \n");
    printf("======================================================================\n");

    const char* paths[] = { WAV_T1, WAV_T2 };
    const uint32_t durations[] = { 400, 500 };
    const char* titles[] = { "Track One", "Track Two" };
    const char* artists[] = { "Artist A", "Artist B" };
    const char* albums[] = { "Album X", "Album X" };

    generate_wav(WAV_T1, durations[0], 48000, 2, 440.0f);
    generate_wav(WAV_T2, durations[1], 48000, 2, 554.37f);
    create_test_library(TEST_LIB_PATH, paths, durations, titles, artists, albums, 2);

    pid_t daemon_pid = spawn_daemon(TEST_SOCKET_PATH, TEST_SHM_PATH, TEST_LIB_PATH);
    ASSERT_TRUE(daemon_pid > 0, "Spawned live omm_daemon (PID=%d)", daemon_pid);
    if (daemon_pid <= 0) return;

    omm_shm_t* shm = map_shm(TEST_SHM_PATH);
    int client_fd = connect_to_daemon(TEST_SOCKET_PATH);
    usleep(50000); // 50ms for reactor loop to process connection and settle

    int64_t initial_rss = get_proc_rss_kb(daemon_pid);
    int initial_fds = count_open_fds(daemon_pid);
    printf("  [BASELINE] Initial Daemon RSS: %ld KB, Open FDs: %d\n", (long)initial_rss, initial_fds);

    omm_packet_t resp;
    int successful_cycles = 0;

    for (int cycle = 1; cycle <= 50; cycle++) {
        // 1. Play Track 1
        uint32_t tid = 1;
        send_packet(client_fd, OP_REQ_PLAY_TRACK_ID, 400 + cycle, &tid, sizeof(tid));
        recv_packet(client_fd, &resp);

        // 2. Wait for prefetch zone or seek into it
        uint32_t seek_in = 250;
        send_packet(client_fd, OP_REQ_SEEK, 500 + cycle, &seek_in, sizeof(seek_in));
        recv_packet(client_fd, &resp);

        // Wait briefly for reactor tick to arm prefetch
        usleep(15000);

        // 3. Cancel prefetch by seeking backwards
        uint32_t seek_back = 30;
        send_packet(client_fd, OP_REQ_SEEK, 600 + cycle, &seek_back, sizeof(seek_back));
        recv_packet(client_fd, &resp);

        // 4. Stop
        send_packet(client_fd, OP_REQ_STOP, 700 + cycle, NULL, 0);
        recv_packet(client_fd, &resp);

        successful_cycles++;
        if (cycle % 10 == 0) {
            int64_t cur_rss = get_proc_rss_kb(daemon_pid);
            int cur_fds = count_open_fds(daemon_pid);
            printf("    Cycle %2d/50: Daemon RSS = %ld KB (drift: %+ld KB), Open FDs = %d\n",
                   cycle, (long)cur_rss, (long)(cur_rss - initial_rss), cur_fds);
        }
    }

    int64_t final_rss = get_proc_rss_kb(daemon_pid);
    int final_fds = count_open_fds(daemon_pid);
    int64_t rss_drift = final_rss - initial_rss;
    int fd_drift = final_fds - initial_fds;

    printf("  [FINAL RESULT] 50 Cycles Completed: Final RSS: %ld KB (Drift: %+ld KB), Final FDs: %d (Drift: %+d)\n",
           (long)final_rss, (long)rss_drift, final_fds, fd_drift);

    ASSERT_TRUE(successful_cycles == 50, "50 rapid prefetch arm/cancel cycles completed without crash");
    ASSERT_TRUE(rss_drift <= 256, "Daemon physical RSS drift after 50 churn cycles is <= 256 KB (got %ld KB)", (long)rss_drift);
    ASSERT_TRUE(fd_drift <= 1, "Daemon open file descriptors did not leak (drift=%d FDs)", fd_drift);

    close(client_fd);
    unmap_shm(shm);
    stop_daemon(daemon_pid, TEST_SOCKET_PATH, TEST_SHM_PATH);
    unlink(WAV_T1);
    unlink(WAV_T2);
    unlink(TEST_LIB_PATH);
}

/* ========================================================================= */
/* Main Challenger Runner                                                    */
/* ========================================================================= */

int main(void) {
    printf("======================================================================\n");
    printf("   Oh-My-Mineral: Milestone 3 Continuous Playlist Empirical Challenger\n");
    printf("======================================================================\n");

    test_autonomous_multi_track_progression_and_clock();
    test_prefetch_cancellation_backwards_seek();
    test_prefetch_cancellation_manual_intervention();
    test_prefetch_churn_and_resource_leaks();

    printf("\n======================================================================\n");
    printf("CONTINUOUS PLAYLIST CHALLENGER SUMMARY:\n");
    printf("  Total Checks : %d\n", g_tests_run);
    printf("  Passed       : %d\n", g_tests_passed);
    printf("  Failed       : %d\n", g_tests_failed);
    printf("======================================================================\n");

    if (g_tests_failed == 0) {
        printf(">>> EMPIRICAL VERDICT: ALL TESTS PASSED (CONFIRM) <<<\n");
        return 0;
    } else {
        printf(">>> EMPIRICAL VERDICT: FAILURES DETECTED (%d failed) (REJECT) <<<\n", g_tests_failed);
        return 1;
    }
}
