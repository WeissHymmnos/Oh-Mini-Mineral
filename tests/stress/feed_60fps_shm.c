#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include "omm_abi.h"

#ifndef OMM_SHM_NAME
#define OMM_SHM_NAME "/omm_shm"
#endif

#ifndef OMM_SHM_VERSION
#define OMM_SHM_VERSION 1
#endif

static inline void seqlock_write_begin(volatile uint64_t* seq) {
    __atomic_add_fetch(seq, 1, __ATOMIC_ACQUIRE);
    __builtin_ia32_sfence();
}

static inline void seqlock_write_end(volatile uint64_t* seq) {
    __builtin_ia32_sfence();
    __atomic_add_fetch(seq, 1, __ATOMIC_RELEASE);
}

int main(int argc, char* argv[]) {
    int duration_sec = 32;
    const char* shm_path = OMM_SHM_NAME;

    if (argc >= 2) duration_sec = atoi(argv[1]);
    if (argc >= 3) shm_path = argv[2];

    printf("[60FPS-Feeder] Opening shared memory %s for %d seconds...\n", shm_path, duration_sec);

    int fd = shm_open(shm_path, O_RDWR | O_CREAT, 0666);
    if (fd < 0) {
        perror("shm_open");
        return 1;
    }
    if (ftruncate(fd, sizeof(omm_shm_t)) != 0) {
        perror("ftruncate");
        close(fd);
        return 1;
    }

    omm_shm_t* shm = (omm_shm_t*)mmap(NULL, sizeof(omm_shm_t), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);

    if (shm == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    // Initialize header if needed
    if (shm->magic != OMM_SHM_MAGIC) {
        shm->magic = OMM_SHM_MAGIC;
        shm->version = OMM_SHM_VERSION;
        shm->spectrum_bands = OMM_SPECTRUM_BANDS;
        shm->volume = 0.85f;
    }

    strncpy((char*)shm->track_title, "Stress Test Audio 60 FPS", sizeof(shm->track_title) - 1);
    strncpy((char*)shm->track_artist, "Empirical Challenger", sizeof(shm->track_artist) - 1);
    strncpy((char*)shm->track_album, "Milestone 4 Benchmark", sizeof(shm->track_album) - 1);
    shm->duration_ms = 300000;
    shm->playback_state = OMM_STATE_PLAYING;

    int total_frames = duration_sec * 60;
    printf("[60FPS-Feeder] Feeding %d frames at 60 FPS (~16.66 ms/frame)...\n", total_frames);

    struct timespec frame_duration;
    frame_duration.tv_sec = 0;
    frame_duration.tv_nsec = 16666667; // 16.666 ms

    float mags[OMM_SPECTRUM_BANDS];
    float peaks[OMM_SPECTRUM_BANDS];
    uint8_t qbars[OMM_SPECTRUM_BANDS];

    for (int b = 0; b < OMM_SPECTRUM_BANDS; b++) {
        peaks[b] = 0.0f;
    }

    for (int f = 0; f < total_frames; f++) {
        float t = (float)f * 0.1f;
        for (int b = 0; b < OMM_SPECTRUM_BANDS; b++) {
            float v = (sinf(t + (float)b * 0.15f) * 0.5f + 0.5f) * (1.0f - (float)b / 80.0f);
            if (v < 0.0f) v = 0.0f;
            if (v > 1.0f) v = 1.0f;
            mags[b] = v;
            if (v > peaks[b]) peaks[b] = v;
            else peaks[b] = peaks[b] * 0.95f; // decay
            qbars[b] = (uint8_t)(v * 8.0f);
        }

        seqlock_write_begin(&shm->seqlock);
        shm->position_ms = (uint32_t)(f * 16.666f);
        shm->spectrum_seq++;
        memcpy(shm->spectrum_mags, mags, sizeof(mags));
        memcpy(shm->spectrum_peaks, peaks, sizeof(peaks));
        memcpy(shm->quantized_bars, qbars, sizeof(qbars));
        seqlock_write_end(&shm->seqlock);

        nanosleep(&frame_duration, NULL);
    }

    printf("[60FPS-Feeder] Completed %d frames fed.\n", total_frames);
    munmap(shm, sizeof(omm_shm_t));
    return 0;
}
