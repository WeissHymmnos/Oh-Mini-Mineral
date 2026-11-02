#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>

#include "omm_abi.h"
#include "miniaudio_wrapper.h"

#define TEST_PASS 0
#define TEST_FAIL 1

static int g_tests_run = 0;
static int g_tests_passed = 0;
static int g_tests_failed = 0;

#define ASSERT_TRUE(cond, msg, ...) do { \
    g_tests_run++; \
    if (cond) { \
        printf("  [PASS] " msg "\n", ##__VA_ARGS__); \
        g_tests_passed++; \
    } else { \
        printf("  [FAIL] " msg " (Line %d)\n", ##__VA_ARGS__, __LINE__); \
        g_tests_failed++; \
    } \
} while(0)

/* Helper: Generate a compliant PCM WAV file */
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

/* ========================================================================= */
/* SUITE 1: 60 FPS SHM Spectrum Updates & Seqlock Concurrency Integrity     */
/* ========================================================================= */

typedef struct {
    omm_shm_t* shm;
    volatile bool stop;
    uint64_t successful_reads;
    uint64_t torn_reads;
    uint64_t retries;
} reader_arg_t;

static void* concurrent_seqlock_reader(void* arg) {
    reader_arg_t* r = (reader_arg_t*)arg;
    omm_shm_t* shm = r->shm;
    float local_mags[64];

    while (!r->stop) {
        uint64_t s1, s2;
        int spin_count = 0;

        do {
            s1 = __atomic_load_n(&shm->seqlock, __ATOMIC_ACQUIRE);
            while ((s1 & 1) != 0) {
                #if defined(__x86_64__) || defined(_M_X64)
                __builtin_ia32_pause();
                #endif
                s1 = __atomic_load_n(&shm->seqlock, __ATOMIC_ACQUIRE);
                spin_count++;
                if (spin_count > 10000000) {
                    r->torn_reads++;
                    return NULL; /* Deadlock detected */
                }
            }
            __builtin_ia32_lfence();

            /* Read spectrum mags snapshot */
            memcpy(local_mags, (const void*)shm->spectrum_mags, sizeof(local_mags));

            __builtin_ia32_lfence();
            s2 = __atomic_load_n(&shm->seqlock, __ATOMIC_ACQUIRE);
            if (s1 != s2) {
                r->retries++;
            }
        } while (s1 != s2);

        /* Verify data consistency: mags must be in valid [0.0, 1.0] range */
        for (int i = 0; i < 64; i++) {
            if (isnan(local_mags[i]) || local_mags[i] < 0.0f || local_mags[i] > 1.0f) {
                r->torn_reads++;
                break;
            }
        }

        r->successful_reads++;
    }
    return NULL;
}

static void test_60fps_spectrum_and_seqlock(void) {
    printf("\n=== [CHALLENGE 1] 60 FPS SHM Spectrum Updates & Seqlock Integrity ===\n");

    const char* wav_path = "/tmp/omm_challenger_test_60fps.wav";
    generate_wav(wav_path, 3000, 48000, 2, 440.0f); // 3-second 440 Hz tone

    omm_shm_t shm;
    memset(&shm, 0, sizeof(shm));
    shm.magic = OMM_SHM_MAGIC;
    shm.version = 1;
    shm.spectrum_bands = 64;

    int32_t rc = omm_audio_init(&shm);
    ASSERT_TRUE(rc == 0, "omm_audio_init returns 0 (initialized miniaudio engine)");

    rc = omm_audio_play_file(wav_path);
    ASSERT_TRUE(rc == 0, "omm_audio_play_file succeeds on valid 440Hz WAV file");

    usleep(100000); // 100ms warm-up
    ASSERT_TRUE(shm.playback_state == OMM_STATE_PLAYING, "shm.playback_state is OMM_STATE_PLAYING (1)");

    /* Measure spectrum updates over 1.0 second */
    uint32_t start_seq = shm.spectrum_seq;
    uint64_t start_seqlock = shm.seqlock;
    
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    usleep(1000000); // exactly 1 second
    gettimeofday(&t1, NULL);

    uint32_t end_seq = shm.spectrum_seq;
    uint64_t end_seqlock = shm.seqlock;
    double elapsed_sec = (t1.tv_sec - t0.tv_sec) + (t1.tv_usec - t0.tv_usec) / 1000000.0;

    uint32_t frames_updated = end_seq - start_seq;
    double fps = (double)frames_updated / elapsed_sec;

    printf("  [INFO] Spectrum frames updated: %u in %.3f s -> %.2f FPS (Seqlock delta: %lu)\n",
           frames_updated, elapsed_sec, fps, (unsigned long)(end_seqlock - start_seqlock));

    ASSERT_TRUE(fps >= 58.0 && fps <= 62.0, "Spectrum update frequency is 60 FPS (58.0-62.0 FPS strict tolerance): actual %.2f FPS", fps);
    ASSERT_TRUE(end_seqlock > start_seqlock, "Seqlock counter advanced monotonically during playback");
    ASSERT_TRUE((shm.seqlock & 1) == 0, "Seqlock version counter is even (stable state) after writes");

    /* Verify FFT spectrum magnitudes */
    float max_mag = 0.0f;
    int non_zero_bands = 0;
    for (int b = 0; b < 64; b++) {
        if (shm.spectrum_mags[b] > 0.001f) non_zero_bands++;
        if (shm.spectrum_mags[b] > max_mag) max_mag = shm.spectrum_mags[b];
    }
    ASSERT_TRUE(non_zero_bands > 0, "FFT spectrum bins contain active audio energy (%d non-zero bands, max=%.3f)",
                non_zero_bands, max_mag);

    /* Spin up 4 concurrent high-frequency Seqlock readers */
    printf("  [INFO] Spawning 4 concurrent reader threads reading SHM at max rate for 500ms...\n");
    pthread_t threads[4];
    reader_arg_t args[4];

    for (int i = 0; i < 4; i++) {
        args[i].shm = &shm;
        args[i].stop = false;
        args[i].successful_reads = 0;
        args[i].torn_reads = 0;
        args[i].retries = 0;
        pthread_create(&threads[i], NULL, concurrent_seqlock_reader, &args[i]);
    }

    usleep(500000); // 500ms concurrent reading stress

    for (int i = 0; i < 4; i++) {
        args[i].stop = true;
    }
    for (int i = 0; i < 4; i++) {
        pthread_join(threads[i], NULL);
    }

    uint64_t total_reads = 0;
    uint64_t total_torn = 0;
    uint64_t total_retries = 0;
    for (int i = 0; i < 4; i++) {
        total_reads += args[i].successful_reads;
        total_torn += args[i].torn_reads;
        total_retries += args[i].retries;
    }

    printf("  [INFO] 4 Readers completed %lu consistent reads, %lu retries, %lu torn reads\n",
           (unsigned long)total_reads, (unsigned long)total_retries, (unsigned long)total_torn);

    ASSERT_TRUE(total_reads > 20000000, "High-frequency concurrent readers completed >20,000,000 consistent snapshots (actual %lu)", (unsigned long)total_reads);
    ASSERT_TRUE(total_torn == 0, "ZERO torn reads detected under 4-reader concurrent contention");

    omm_audio_stop();
    omm_audio_uninit();
    unlink(wav_path);
}

/* ========================================================================= */
/* SUITE 1B: 10+ Seconds Playback Zero Accumulator Drift Empirical Check     */
/* ========================================================================= */

static void test_10s_zero_accumulator_drift(void) {
    printf("\n=== [CHALLENGE 1B] 10+ Seconds Playback Zero Accumulator Drift ===\n");

    const char* wav_path = "/tmp/omm_challenger_test_10s_drift.wav";
    // 13-second 440 Hz WAV file
    generate_wav(wav_path, 13000, 48000, 2, 440.0f);

    omm_shm_t shm;
    memset(&shm, 0, sizeof(shm));
    shm.magic = OMM_SHM_MAGIC;
    shm.version = 1;
    shm.spectrum_bands = 64;

    int32_t rc = omm_audio_init(&shm);
    ASSERT_TRUE(rc == 0, "omm_audio_init initialized for 10s drift test");

    rc = omm_audio_play_file(wav_path);
    ASSERT_TRUE(rc == 0, "omm_audio_play_file started 13-second test file");

    usleep(100000); // 100ms warm-up

    uint32_t base_seq = shm.spectrum_seq;
    struct timeval t_base, t_prev, t_curr;
    gettimeofday(&t_base, NULL);
    t_prev = t_base;
    uint32_t prev_seq = base_seq;

    bool all_seconds_in_tolerance = true;
    uint32_t max_drift_frames = 0;

    for (int sec = 1; sec <= 10; sec++) {
        usleep(1000000);
        gettimeofday(&t_curr, NULL);

        uint32_t cur_seq = shm.spectrum_seq;
        double interval_sec = (t_curr.tv_sec - t_prev.tv_sec) + (t_curr.tv_usec - t_prev.tv_usec) / 1000000.0;
        double total_sec = (t_curr.tv_sec - t_base.tv_sec) + (t_curr.tv_usec - t_base.tv_usec) / 1000000.0;

        uint32_t step_frames = cur_seq - prev_seq;
        uint32_t total_frames = cur_seq - base_seq;

        double step_fps = (double)step_frames / interval_sec;
        double cum_fps = (double)total_frames / total_sec;

        uint32_t expected_frames = (uint32_t)(60.0 * total_sec + 0.5);
        int32_t drift = (int32_t)total_frames - (int32_t)expected_frames;
        if (abs(drift) > (int32_t)max_drift_frames) max_drift_frames = abs(drift);

        printf("  [DRIFT PROBE t=%2ds] step: %u frames (%.2f FPS) | cum: %u frames (%.2f FPS) | drift: %+d frames\n",
               sec, step_frames, step_fps, total_frames, cum_fps, drift);

        if (step_fps < 58.0 || step_fps > 62.0) {
            all_seconds_in_tolerance = false;
        }

        t_prev = t_curr;
        prev_seq = cur_seq;
    }

    ASSERT_TRUE(all_seconds_in_tolerance, "Every 1.0s interval FPS stayed strictly within 58.0-62.0 FPS");
    ASSERT_TRUE(max_drift_frames <= 3, "Accumulator drift is ZERO/bounded across 10s playback (max drift: %u frames)", max_drift_frames);
    ASSERT_TRUE(shm.playback_state == OMM_STATE_PLAYING, "Playback state remains PLAYING at 10s mark");

    omm_audio_stop();
    omm_audio_uninit();
    unlink(wav_path);
}

/* ========================================================================= */
/* SUITE 2: 200ms Ring Buffer Underrun Protection & Recovery                 */
/* ========================================================================= */

typedef struct {
    int mode; /* 0=normal, 1=underrun (timeout), 2=recovered */
    uint32_t call_count;
    uint32_t timeout_count;
    float test_freq;
} mock_stream_t;

static int32_t mock_stream_read(void* stream_handle, uint8_t* buffer, size_t count, size_t* out_read) {
    mock_stream_t* s = (mock_stream_t*)stream_handle;
    s->call_count++;

    if (s->mode == 1) {
        /* Simulate slow / stalled streaming feed: simulate 200ms timeout */
        usleep(10000); // 10ms wait in audio thread
        s->timeout_count++;
        *out_read = 0;
        return OMM_ERR_STREAM_TIMEOUT;
    }

    /* Normal mode or recovered mode: synthesize valid float PCM stereo frames */
    float* fbuf = (float*)buffer;
    size_t frames = count / (2 * sizeof(float));
    for (size_t i = 0; i < frames; i++) {
        float val = sinf(2.0f * (float)M_PI * s->test_freq * (float)i / 48000.0f) * 0.5f;
        fbuf[i * 2 + 0] = val;
        fbuf[i * 2 + 1] = val;
    }
    *out_read = count;
    return OMM_OK;
}

static int32_t mock_stream_seek(void* stream_handle, int64_t offset, int32_t whence, int64_t* out_pos) {
    (void)stream_handle; (void)offset; (void)whence;
    if (out_pos) *out_pos = offset;
    return OMM_OK;
}

static void test_200ms_underrun_protection_and_recovery(void) {
    printf("\n=== [CHALLENGE 2] 200ms Ring Buffer Underrun Protection & Recovery ===\n");

    omm_shm_t shm;
    memset(&shm, 0, sizeof(shm));
    shm.magic = OMM_SHM_MAGIC;
    shm.version = 1;
    shm.spectrum_bands = 64;

    omm_audio_init(&shm);

    mock_stream_t stream;
    memset(&stream, 0, sizeof(stream));
    stream.mode = 0; // normal
    stream.test_freq = 1000.0f;

    int32_t rc = omm_audio_play_stream(&stream, mock_stream_read, mock_stream_seek);
    ASSERT_TRUE(rc == 0, "omm_audio_play_stream initiated with mock stream");

    usleep(100000); // 100ms normal playback
    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_STREAMING) != 0, "OMM_FLAG_STREAMING asserted in SHM");
    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_UNDERRUN) == 0, "OMM_FLAG_UNDERRUN initially clear");

    uint32_t pos_before_underrun = shm.position_ms;
    uint32_t underruns_before = shm.underrun_counter;

    /* Simulate stalled streaming feed (Trigger underruns) */
    printf("  [INFO] Stalling mock stream feed to simulate network packet delay / stall...\n");
    stream.mode = 1; // underrun mode: returns OMM_ERR_STREAM_TIMEOUT

    usleep(250000); // 250ms of stalled stream

    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_UNDERRUN) != 0, "OMM_FLAG_UNDERRUN asserted during stream stall");
    ASSERT_TRUE(shm.underrun_counter > underruns_before,
                "underrun_counter incremented (before=%u, after=%u)", underruns_before, shm.underrun_counter);
    ASSERT_TRUE(shm.position_ms > pos_before_underrun,
                "Audio clock preserved during underrun silence frames (pos_before=%u ms, pos_now=%u ms)",
                pos_before_underrun, shm.position_ms);

    /* Verify audio silence frames generated during underrun */
    bool silence_in_tap = true;
    for (int i = 0; i < 512; i++) {
        if (fabsf(shm.oscilloscope_tap[i]) > 0.0001f) {
            silence_in_tap = false;
            break;
        }
    }
    ASSERT_TRUE(silence_in_tap, "Oscilloscope waveform contains silence frames during underrun");

    /* Recovery: Resume valid audio stream */
    printf("  [INFO] Resuming streaming feed to verify underrun recovery...\n");
    stream.mode = 2; // recovered mode: returns valid PCM frames

    usleep(200000); // 200ms resumed playback

    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_UNDERRUN) == 0, "OMM_FLAG_UNDERRUN cleanly cleared upon stream recovery");
    ASSERT_TRUE(shm.playback_state == OMM_STATE_PLAYING, "Playback state remains OMM_STATE_PLAYING after recovery");

    /* Verify audio is producing sound again */
    bool non_zero_after_recovery = false;
    for (int i = 0; i < 512; i++) {
        if (fabsf(shm.oscilloscope_tap[i]) > 0.001f) {
            non_zero_after_recovery = true;
            break;
        }
    }
    ASSERT_TRUE(non_zero_after_recovery, "Audio waveform restored non-zero signal after recovery");

    omm_audio_stop();
    omm_audio_uninit();
}

/* ========================================================================= */
/* SUITE 3: Gapless Prefetch (20s) & Seamless Decoder Swap                  */
/* ========================================================================= */

static void test_gapless_prefetch_and_decoder_swap(void) {
    printf("\n=== [CHALLENGE 3] Gapless Prefetch & Seamless Decoder Swap ===\n");

    const char* t1_path = "/tmp/omm_challenger_t1_short.wav";
    const char* t2_path = "/tmp/omm_challenger_t2_next.wav";

    /* Track 1: 400ms duration, 440 Hz */
    generate_wav(t1_path, 400, 48000, 2, 440.0f);
    /* Track 2: 800ms duration, 880 Hz */
    generate_wav(t2_path, 800, 48000, 2, 880.0f);

    omm_shm_t shm;
    memset(&shm, 0, sizeof(shm));
    shm.magic = OMM_SHM_MAGIC;
    shm.version = 1;
    shm.spectrum_bands = 64;

    omm_audio_init(&shm);

    int32_t rc = omm_audio_play_file(t1_path);
    ASSERT_TRUE(rc == 0, "omm_audio_play_file starts Track 1 (400ms)");
    ASSERT_TRUE(omm_audio_get_duration_ms() == 400, "Track 1 duration reported as 400 ms (actual %u)", omm_audio_get_duration_ms());

    /* Prefetch Track 2 */
    rc = omm_audio_prefetch_file(t2_path);
    ASSERT_TRUE(rc == 0, "omm_audio_prefetch_file pre-opens Track 2 (800ms)");
    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_PREFETCHING) != 0, "OMM_FLAG_PREFETCHING asserted in SHM");

    /* Wait for Track 1 to reach completion and transition to Track 2 */
    printf("  [INFO] Waiting 500ms for Track 1 completion and gapless transition...\n");
    usleep(500000); // 500ms > 400ms

    /* Check if decoder swap occurred */
    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_PREFETCHING) == 0,
                "OMM_FLAG_PREFETCHING cleared upon seamless decoder swap");
    ASSERT_TRUE(shm.playback_state == OMM_STATE_PLAYING,
                "Playback state continues as OMM_STATE_PLAYING across track boundary");

    /* EMPIRICAL PROBE & STRICT ASSERTIONS: Check position and duration after swap */
    uint32_t pos_after = omm_audio_get_position_ms();
    uint32_t dur_after = omm_audio_get_duration_ms();
    printf("  [PROBE] After swap: position_ms = %u ms, duration_ms = %u ms (Track 2 is 800 ms)\n", pos_after, dur_after);

    ASSERT_TRUE(dur_after == 800, "Track 2 duration_ms in audio engine updated to 800 ms (actual %u ms)", dur_after);
    ASSERT_TRUE(shm.duration_ms == 800, "Track 2 duration_ms in SHM updated to 800 ms (actual %u ms)", shm.duration_ms);
    ASSERT_TRUE(pos_after < 800, "Track 2 position_ms in audio engine reset and within bounds (actual %u ms)", pos_after);
    ASSERT_TRUE(shm.position_ms < 800, "Track 2 position_ms in SHM reset and within bounds (actual %u ms)", shm.position_ms);

    /* Verify continuous PCM audio energy in oscilloscope tap (no glitch or silent drop) */
    bool audio_active = false;
    for (int i = 0; i < 512; i++) {
        if (fabsf(shm.oscilloscope_tap[i]) > 0.001f) {
            audio_active = true;
            break;
        }
    }
    ASSERT_TRUE(audio_active, "Oscilloscope tap contains continuous PCM audio after decoder swap (no stall/glitch)");

    /* Multi-track chaining: Prefetch Track 3 (600ms) while Track 2 is playing */
    const char* t3_path = "/tmp/omm_challenger_t3_chain.wav";
    generate_wav(t3_path, 600, 48000, 2, 1200.0f);

    rc = omm_audio_prefetch_file(t3_path);
    ASSERT_TRUE(rc == 0, "Prefetch Track 3 (600ms) succeeds during active Track 2 playback");
    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_PREFETCHING) != 0, "OMM_FLAG_PREFETCHING asserted for Track 3");

    /* Wait for Track 2 to finish and transition to Track 3 */
    printf("  [INFO] Waiting for Track 2 completion and transition to Track 3...\n");
    usleep(850000); // 850ms (> 736ms remaining in Track 2)

    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_PREFETCHING) == 0, "OMM_FLAG_PREFETCHING cleared upon Track 3 swap");
    ASSERT_TRUE(shm.playback_state == OMM_STATE_PLAYING, "Playback continues as PLAYING on Track 3");
    uint32_t dur3 = omm_audio_get_duration_ms();
    uint32_t pos3 = omm_audio_get_position_ms();
    ASSERT_TRUE(dur3 == 600, "Track 3 duration_ms updated to 600 ms (actual %u ms)", dur3);
    ASSERT_TRUE(shm.duration_ms == 600, "Track 3 SHM duration_ms updated to 600 ms (actual %u ms)", shm.duration_ms);
    ASSERT_TRUE(pos3 < 600, "Track 3 position_ms reset and < 600 ms (actual %u ms)", pos3);

    /* Test prefetch cancellation */
    const char* t4_path = "/tmp/omm_challenger_t4_cancel.wav";
    generate_wav(t4_path, 500, 48000, 2, 600.0f);
    rc = omm_audio_prefetch_file(t4_path);
    ASSERT_TRUE(rc == 0, "Prefetch Track 4 initiated");
    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_PREFETCHING) != 0, "OMM_FLAG_PREFETCHING asserted for Track 4");

    rc = omm_audio_cancel_prefetch();
    ASSERT_TRUE(rc == 0, "omm_audio_cancel_prefetch() returned 0");
    ASSERT_TRUE((shm.playback_flags & OMM_FLAG_PREFETCHING) == 0, "OMM_FLAG_PREFETCHING cleared after cancel");
    ASSERT_TRUE(shm.playback_state == OMM_STATE_PLAYING, "Playback continues unaffected after prefetch cancel");

    omm_audio_stop();
    omm_audio_uninit();
    unlink(t1_path);
    unlink(t2_path);
    unlink(t3_path);
    unlink(t4_path);
}

int main(void) {
    printf("======================================================================\n");
    printf("   Oh-My-Mineral: Milestone 3 Audio Pipeline Empirical Challenger     \n");
    printf("======================================================================\n");

    test_60fps_spectrum_and_seqlock();
    test_10s_zero_accumulator_drift();
    test_200ms_underrun_protection_and_recovery();
    test_gapless_prefetch_and_decoder_swap();

    printf("\n======================================================================\n");
    printf("CHALLENGE HARNESS SUMMARY:\n");
    printf("  Total Checks : %d\n", g_tests_run);
    printf("  Passed       : %d\n", g_tests_passed);
    printf("  Failed       : %d\n", g_tests_failed);
    printf("======================================================================\n");

    if (g_tests_failed == 0) {
        printf(">>> VERDICT: ALL AUDIO PIPELINE TESTS PASSED <<<\n");
        return 0;
    } else {
        printf(">>> VERDICT: FAILURES DETECTED (%d failed) <<<\n", g_tests_failed);
        return 1;
    }
}
