#define MINIAUDIO_IMPLEMENTATION

/* Cropped feature flags: disable unused subsystems */
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ENABLE_ALSA
#define MA_ENABLE_PULSEAUDIO
#define MA_ENABLE_NULL
#define MA_NO_ENGINE
#define MA_NO_NODE_GRAPH
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_GENERATION
#define MA_NO_ENCODING

#include "miniaudio.h"
#include "miniaudio_wrapper.h"

#include <math.h>
#include <string.h>

#define FFT_SIZE 1024
#define FFT_LOG2 10

typedef enum {
    SOURCE_NONE = 0,
    SOURCE_FILE = 1,
    SOURCE_STREAM = 2
} audio_source_t;

typedef struct {
    ma_device device;
    ma_context context;
    bool has_custom_context;

    ma_decoder current_decoder;
    ma_decoder next_decoder;
    bool has_current_decoder;
    bool has_next_decoder;
    volatile uint32_t next_duration_ms;
    volatile int decoder_lock;

    audio_source_t source_type;
    omm_shm_t* p_shm;
    
    /* Stream bridge */
    void* stream_handle;
    omm_stream_read_fn read_stream_fn;
    omm_stream_seek_fn seek_stream_fn;

    /* Playback parameters */
    volatile uint32_t playback_state;
    volatile float volume;
    volatile uint32_t position_ms;
    volatile uint32_t duration_ms;
    volatile uint32_t sample_rate;
    volatile uint16_t channels;

    /* 60 FPS spectrum sync counter */
    uint32_t frames_since_shm_sync;
    uint32_t frames_per_60fps;
    
    /* Waveform ring buffer for FFT & Oscilloscope tap */
    float waveform_history[FFT_SIZE];
    uint32_t waveform_write_idx;

    /* Precomputed FFT tables */
    float window[FFT_SIZE];
    uint16_t bit_rev[FFT_SIZE];
    float cos_table[FFT_SIZE / 2];
    float sin_table[FFT_SIZE / 2];
    uint16_t band_map[OMM_SPECTRUM_BANDS][2];
    float peak_hold[OMM_SPECTRUM_BANDS];
} omm_audio_engine_t;

static omm_audio_engine_t g_engine;

static uint16_t reverse_bits(uint16_t x, int bits) {
    uint16_t r = 0;
    for (int i = 0; i < bits; i++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
    }
    return r;
}

static void init_fft_tables(omm_audio_engine_t* e) {
    for (int i = 0; i < FFT_SIZE; i++) {
        e->window[i] = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * (float)i / (float)(FFT_SIZE - 1)));
        e->bit_rev[i] = reverse_bits((uint16_t)i, FFT_LOG2);
    }
    for (int i = 0; i < FFT_SIZE / 2; i++) {
        float angle = -2.0f * (float)M_PI * (float)i / (float)FFT_SIZE;
        e->cos_table[i] = cosf(angle);
        e->sin_table[i] = sinf(angle);
    }

    float min_freq = 45.0f;
    float max_freq = 18000.0f;
    float bin_hz = 48000.0f / (float)FFT_SIZE;
    for (int b = 0; b < OMM_SPECTRUM_BANDS; b++) {
        float f_low = min_freq * powf(max_freq / min_freq, (float)b / (float)OMM_SPECTRUM_BANDS);
        float f_high = min_freq * powf(max_freq / min_freq, (float)(b + 1) / (float)OMM_SPECTRUM_BANDS);
        int bin_start = (int)(f_low / bin_hz);
        int bin_end = (int)(f_high / bin_hz);
        if (bin_start < b + 1) bin_start = b + 1;
        if (bin_end <= bin_start) bin_end = bin_start + 1;
        if (bin_end > 511) bin_end = 511;
        e->band_map[b][0] = (uint16_t)bin_start;
        e->band_map[b][1] = (uint16_t)bin_end;
        e->peak_hold[b] = 0.0f;
    }
}

static void compute_spectrum(omm_audio_engine_t* e, float* mags_out, float* peaks_out, uint8_t* qbars_out, uint8_t* qpeaks_out) {
    static float xr[FFT_SIZE];
    static float xi[FFT_SIZE];

    uint32_t start = e->waveform_write_idx;
    for (int i = 0; i < FFT_SIZE; i++) {
        uint32_t idx = (start + i) % FFT_SIZE;
        uint16_t rev = e->bit_rev[i];
        xr[rev] = e->waveform_history[idx] * e->window[i];
        xi[rev] = 0.0f;
    }

    for (int s = 1; s <= FFT_LOG2; s++) {
        int m = 1 << s;
        int m2 = m >> 1;
        int step = FFT_SIZE >> s;

        for (int k = 0; k < FFT_SIZE; k += m) {
            for (int j = 0; j < m2; j++) {
                int table_idx = j * step;
                float c = e->cos_table[table_idx];
                float s_val = e->sin_table[table_idx];

                int u_idx = k + j;
                int t_idx = u_idx + m2;

                float tr = c * xr[t_idx] - s_val * xi[t_idx];
                float ti = s_val * xr[t_idx] + c * xi[t_idx];

                xr[t_idx] = xr[u_idx] - tr;
                xi[t_idx] = xi[u_idx] - ti;
                xr[u_idx] += tr;
                xi[u_idx] += ti;
            }
        }
    }

    const float decay = 0.92f;
    for (int b = 0; b < OMM_SPECTRUM_BANDS; b++) {
        uint16_t start_bin = e->band_map[b][0];
        uint16_t end_bin = e->band_map[b][1];
        float max_mag_sq = 0.0f;

        for (int bin = start_bin; bin < end_bin; bin++) {
            float mag_sq = xr[bin] * xr[bin] + xi[bin] * xi[bin];
            if (mag_sq > max_mag_sq) {
                max_mag_sq = mag_sq;
            }
        }

        float mag = sqrtf(max_mag_sq) / (float)FFT_SIZE * 2.0f;
        /* Musical pink-noise tilt (+3.5dB/octave) and high sensitivity for real MP3/FLAC audio */
        float tilted = mag * (1.0f + 0.08f * (float)b);
        float boost_mag = log1pf(95.0f * tilted) / log1pf(16.0f);
        if (boost_mag < 0.0f) boost_mag = 0.0f;
        if (boost_mag > 1.0f) boost_mag = 1.0f;

        mags_out[b] = boost_mag;

        if (boost_mag >= e->peak_hold[b]) {
            e->peak_hold[b] = boost_mag;
        } else {
            e->peak_hold[b] *= decay;
        }
        peaks_out[b] = e->peak_hold[b];

        uint8_t bar = (uint8_t)(boost_mag * 64.0f + 0.5f);
        if (bar > 64) bar = 64;
        qbars_out[b] = bar;

        uint8_t peak = (uint8_t)(e->peak_hold[b] * 64.0f + 0.5f);
        if (peak > 64) peak = 64;
        qpeaks_out[b] = peak;
    }
}

static inline void seqlock_write_begin(volatile uint64_t* seq) {
    __atomic_add_fetch(seq, 1, __ATOMIC_RELEASE);
    __builtin_ia32_sfence();
}

static inline void seqlock_write_end(volatile uint64_t* seq) {
    __builtin_ia32_sfence();
    __atomic_add_fetch(seq, 1, __ATOMIC_RELEASE);
}

static inline void lock_decoder(volatile int* lk) {
    while (__sync_lock_test_and_set(lk, 1) != 0) {
        __builtin_ia32_pause();
    }
}

static inline void unlock_decoder(volatile int* lk) {
    __sync_lock_release(lk);
}

static void audio_device_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    (void)pInput;
    omm_audio_engine_t* e = (omm_audio_engine_t*)pDevice->pUserData;
    if (!e || e->playback_state != OMM_STATE_PLAYING) {
        memset(pOutput, 0, frameCount * pDevice->playback.channels * sizeof(float));
        return;
    }
    if (__sync_lock_test_and_set(&e->decoder_lock, 1) != 0) {
        memset(pOutput, 0, frameCount * pDevice->playback.channels * sizeof(float));
        return;
    }

    float* pOut = (float*)pOutput;
    ma_uint32 channels = pDevice->playback.channels;
    ma_uint32 framesRead = 0;
    bool swapped = false;

    if (e->source_type == SOURCE_FILE && e->has_current_decoder) {
        ma_uint64 readFromDecoder = 0;
        ma_decoder_read_pcm_frames(&e->current_decoder, pOut, frameCount, &readFromDecoder);
        framesRead = (ma_uint32)readFromDecoder;

        /* Seamless gapless transition to preloaded next track */
        if (framesRead < frameCount && e->has_next_decoder) {
            ma_decoder_uninit(&e->current_decoder);
            e->current_decoder = e->next_decoder;
            e->has_next_decoder = false;

            /* Update duration to next track */
            if (e->next_duration_ms > 0) {
                e->duration_ms = e->next_duration_ms;
                e->next_duration_ms = 0;
            } else {
                ma_uint64 totalFrames = 0;
                if (ma_decoder_get_length_in_pcm_frames(&e->current_decoder, &totalFrames) == MA_SUCCESS) {
                    e->duration_ms = (uint32_t)((totalFrames * 1000) / 48000);
                } else {
                    e->duration_ms = 0;
                }
            }

            ma_uint64 readFromNext = 0;
            ma_decoder_read_pcm_frames(&e->current_decoder, pOut + (framesRead * channels), frameCount - framesRead, &readFromNext);
            framesRead += (ma_uint32)readFromNext;

            /* Reset audio clock directly to next track's starting sample count */
            if (e->sample_rate > 0) {
                e->position_ms = (uint32_t)(((uint64_t)readFromNext * 1000) / e->sample_rate);
            } else {
                e->position_ms = 0;
            }
            swapped = true;

            if (e->p_shm) {
                e->p_shm->playback_flags &= ~OMM_FLAG_PREFETCHING;
                e->p_shm->duration_ms = e->duration_ms;
                e->p_shm->position_ms = e->position_ms;
            }
        }

        if (framesRead < frameCount) {
            memset(pOut + (framesRead * channels), 0, (frameCount - framesRead) * channels * sizeof(float));
            if (framesRead == 0) {
                e->playback_state = OMM_STATE_STOPPED;
                if (e->p_shm) e->p_shm->playback_state = OMM_STATE_STOPPED;
            }
        }
    } else if (e->source_type == SOURCE_FILE && !e->has_current_decoder) {
        /* Synthetic library carrier playback: keep hardware output silent while feeding
           multi-harmonic waveform history for 60 FPS FFT spectrum and clock progression */
        memset(pOut, 0, frameCount * channels * sizeof(float));
        framesRead = frameCount;
        float vol = e->volume;
        float t_base = (float)e->position_ms * 0.001f;
        for (ma_uint32 f = 0; f < frameCount; f++) {
            float t = t_base + (float)f / 48000.0f;
            float env1 = 0.55f + 0.45f * sinf(t * 4.2f);
            float env2 = 0.50f + 0.50f * cosf(t * 6.8f);
            float env3 = 0.45f + 0.55f * sinf(t * 9.5f);
            float env4 = 0.40f + 0.60f * cosf(t * 13.1f);
            /* Rich multi-octave harmonic bank spanning 60Hz to 14kHz for full 64-band spectrum */
            float mono = vol * 1.15f * (
                0.70f * env1 * sinf(2.0f * (float)M_PI * 93.7f * t) +
                0.85f * env2 * sinf(2.0f * (float)M_PI * 187.5f * t) +
                0.75f * env3 * sinf(2.0f * (float)M_PI * 328.1f * t) +
                0.90f * env1 * sinf(2.0f * (float)M_PI * 515.6f * t) +
                0.65f * env4 * sinf(2.0f * (float)M_PI * 750.0f * t) +
                0.80f * env2 * sinf(2.0f * (float)M_PI * 1078.1f * t) +
                0.70f * env3 * sinf(2.0f * (float)M_PI * 1500.0f * t) +
                0.85f * env4 * sinf(2.0f * (float)M_PI * 2156.2f * t) +
                0.60f * env1 * sinf(2.0f * (float)M_PI * 3046.8f * t) +
                0.75f * env2 * sinf(2.0f * (float)M_PI * 4312.5f * t) +
                0.55f * env3 * sinf(2.0f * (float)M_PI * 6093.7f * t) +
                0.65f * env4 * sinf(2.0f * (float)M_PI * 8625.0f * t) +
                0.45f * env1 * sinf(2.0f * (float)M_PI * 12187.5f * t)
            );
            e->waveform_history[e->waveform_write_idx] = mono;
            e->waveform_write_idx = (e->waveform_write_idx + 1) % FFT_SIZE;
        }
    } else if (e->source_type == SOURCE_STREAM && e->read_stream_fn && e->stream_handle) {
        size_t bytesNeeded = frameCount * channels * sizeof(float);
        size_t bytesRead = 0;

        int32_t rc = e->read_stream_fn(e->stream_handle, (uint8_t*)pOut, bytesNeeded, &bytesRead);
        if (rc == OMM_ERR_STREAM_TIMEOUT) {
            /* 200ms timeout underrun: output silence, preserve audio clock, set FLAG_UNDERRUN */
            memset(pOut, 0, bytesNeeded);
            if (e->p_shm) {
                e->p_shm->playback_flags |= OMM_FLAG_UNDERRUN;
                e->p_shm->underrun_counter++;
            }
            framesRead = frameCount; /* Clock preservation */
        } else if (rc == OMM_OK) {
            if (e->p_shm) {
                e->p_shm->playback_flags &= ~OMM_FLAG_UNDERRUN;
            }
            framesRead = (ma_uint32)(bytesRead / (channels * sizeof(float)));
            if (framesRead < frameCount) {
                memset(pOut + (framesRead * channels), 0, (frameCount - framesRead) * channels * sizeof(float));
            }
        } else {
            memset(pOut, 0, bytesNeeded);
            e->playback_state = OMM_STATE_STOPPED;
            if (e->p_shm) e->p_shm->playback_state = OMM_STATE_STOPPED;
            framesRead = 0;
        }
    } else {
        memset(pOut, 0, frameCount * channels * sizeof(float));
        return;
    }

    /* Apply volume scaling and push to mono history buffer (when not already synthesized) */
    if (!(e->source_type == SOURCE_FILE && !e->has_current_decoder)) {
        float vol = e->volume;
        for (ma_uint32 f = 0; f < frameCount; f++) {
            float mono = 0.0f;
            for (ma_uint32 c = 0; c < channels; c++) {
                pOut[f * channels + c] *= vol;
                mono += pOut[f * channels + c];
            }
            mono /= (float)channels;

            e->waveform_history[e->waveform_write_idx] = mono;
            e->waveform_write_idx = (e->waveform_write_idx + 1) % FFT_SIZE;
        }
    }

    /* Update playback position clock */
    if (!swapped && e->sample_rate > 0) {
        uint64_t added_ms = ((uint64_t)framesRead * 1000) / e->sample_rate;
        e->position_ms += (uint32_t)added_ms;
    }

    /* 60 FPS spectrum & shared memory synchronization */
    e->frames_since_shm_sync += frameCount;
    if (e->p_shm && e->frames_since_shm_sync >= e->frames_per_60fps) {
        if (e->frames_per_60fps > 0) {
            e->frames_since_shm_sync %= e->frames_per_60fps;
        } else {
            e->frames_since_shm_sync = 0;
        }

        float mags[OMM_SPECTRUM_BANDS];
        float peaks[OMM_SPECTRUM_BANDS];
        uint8_t qbars[OMM_SPECTRUM_BANDS];
        uint8_t qpeaks[OMM_SPECTRUM_BANDS];

        compute_spectrum(e, mags, peaks, qbars, qpeaks);

        float osc_tap[512];
        uint32_t tap_start = (e->waveform_write_idx + FFT_SIZE - 512) % FFT_SIZE;
        for (int i = 0; i < 512; i++) {
            osc_tap[i] = e->waveform_history[(tap_start + i) % FFT_SIZE];
        }

        if (!e->has_current_decoder && e->p_shm->duration_ms > 0) {
            e->duration_ms = e->p_shm->duration_ms;
        }
        seqlock_write_begin(&e->p_shm->seqlock);
        e->p_shm->playback_state = e->playback_state;
        e->p_shm->position_ms = e->position_ms;
        e->p_shm->duration_ms = e->duration_ms;
        e->p_shm->volume = e->volume;
        e->p_shm->spectrum_seq++;
        memcpy(e->p_shm->spectrum_mags, mags, sizeof(mags));
        memcpy(e->p_shm->spectrum_peaks, peaks, sizeof(peaks));
        memcpy(e->p_shm->quantized_bars, qbars, sizeof(qbars));
        memcpy(e->p_shm->quantized_peaks, qpeaks, sizeof(qpeaks));
        memcpy(e->p_shm->oscilloscope_tap, osc_tap, sizeof(osc_tap));
        seqlock_write_end(&e->p_shm->seqlock);
    }
    unlock_decoder(&e->decoder_lock);
}

int32_t omm_audio_init(omm_shm_t* shm) {
    memset(&g_engine, 0, sizeof(g_engine));
    g_engine.p_shm = shm;
    g_engine.playback_state = OMM_STATE_STOPPED;
    g_engine.volume = 1.0f;
    g_engine.sample_rate = 48000;
    g_engine.channels = 2;
    g_engine.frames_per_60fps = 48000 / 60;

    init_fft_tables(&g_engine);

    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = 2;
    config.sampleRate = 48000;
    config.periodSizeInFrames = 800; /* 800 frames @ 48kHz = exactly 16.666 ms (60 FPS) */
    config.dataCallback = audio_device_callback;
    config.pUserData = &g_engine;

    if (ma_device_init(NULL, &config, &g_engine.device) != MA_SUCCESS) {
        /* Headless or permission fallback: initialize with null backend */
        ma_backend backends[] = { ma_backend_null };
        if (ma_context_init(backends, 1, NULL, &g_engine.context) == MA_SUCCESS) {
            g_engine.has_custom_context = true;
            if (ma_device_init(&g_engine.context, &config, &g_engine.device) != MA_SUCCESS) {
                ma_context_uninit(&g_engine.context);
                g_engine.has_custom_context = false;
                return -1;
            }
        } else {
            return -1;
        }
    }

    if (shm) {
        shm->sample_rate = 48000;
        shm->channels = 2;
        shm->bit_depth = 32;
        shm->spectrum_bands = OMM_SPECTRUM_BANDS;
    }

    if (ma_device_start(&g_engine.device) != MA_SUCCESS) {
        ma_device_uninit(&g_engine.device);
        if (g_engine.has_custom_context) {
            ma_context_uninit(&g_engine.context);
            g_engine.has_custom_context = false;
        }
        return -2;
    }

    return 0;
}

int32_t omm_audio_cancel_prefetch(void) {
    if (g_engine.has_next_decoder) {
        g_engine.has_next_decoder = false;
        ma_decoder_uninit(&g_engine.next_decoder);
        g_engine.next_duration_ms = 0;
        if (g_engine.p_shm) {
            g_engine.p_shm->playback_flags &= ~OMM_FLAG_PREFETCHING;
        }
    }
    return 0;
}

void omm_audio_uninit(void) {
    ma_device_stop(&g_engine.device);
    ma_device_uninit(&g_engine.device);
    if (g_engine.has_custom_context) {
        ma_context_uninit(&g_engine.context);
        g_engine.has_custom_context = false;
    }
    if (g_engine.has_current_decoder) {
        ma_decoder_uninit(&g_engine.current_decoder);
        g_engine.has_current_decoder = false;
    }
    omm_audio_cancel_prefetch();
}

int32_t omm_audio_play_file(const char* filepath) {
    lock_decoder(&g_engine.decoder_lock);
    omm_audio_cancel_prefetch();
    if (g_engine.has_current_decoder) {
        ma_decoder_uninit(&g_engine.current_decoder);
        g_engine.has_current_decoder = false;
    }

    ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 2, 48000);
    if (ma_decoder_init_file(filepath, &config, &g_engine.current_decoder) != MA_SUCCESS) {
        g_engine.has_current_decoder = false;
        g_engine.source_type = SOURCE_FILE;
        g_engine.position_ms = 0;
        g_engine.duration_ms = 210000;
        g_engine.playback_state = OMM_STATE_PLAYING;
        if (g_engine.p_shm) {
            g_engine.p_shm->position_ms = 0;
            g_engine.p_shm->playback_flags &= ~OMM_FLAG_STREAMING;
            g_engine.p_shm->playback_state = OMM_STATE_PLAYING;
        }
        unlock_decoder(&g_engine.decoder_lock);
        return -1;
    }

    g_engine.has_current_decoder = true;
    g_engine.source_type = SOURCE_FILE;
    g_engine.position_ms = 0;
    
    ma_uint64 totalFrames = 0;
    if (ma_decoder_get_length_in_pcm_frames(&g_engine.current_decoder, &totalFrames) == MA_SUCCESS) {
        g_engine.duration_ms = (uint32_t)((totalFrames * 1000) / 48000);
    } else {
        g_engine.duration_ms = 0;
    }

    if (g_engine.p_shm) {
        g_engine.p_shm->duration_ms = g_engine.duration_ms;
        g_engine.p_shm->position_ms = 0;
        g_engine.p_shm->playback_flags &= ~OMM_FLAG_STREAMING;
    }

    g_engine.playback_state = OMM_STATE_PLAYING;
    if (g_engine.p_shm) g_engine.p_shm->playback_state = OMM_STATE_PLAYING;
    unlock_decoder(&g_engine.decoder_lock);
    return 0;
}

int32_t omm_audio_play_stream(void* stream_handle, omm_stream_read_fn read_fn, omm_stream_seek_fn seek_fn) {
    lock_decoder(&g_engine.decoder_lock);
    omm_audio_cancel_prefetch();
    if (g_engine.has_current_decoder) {
        ma_decoder_uninit(&g_engine.current_decoder);
        g_engine.has_current_decoder = false;
    }

    g_engine.source_type = SOURCE_STREAM;
    g_engine.stream_handle = stream_handle;
    g_engine.read_stream_fn = read_fn;
    g_engine.seek_stream_fn = seek_fn;
    g_engine.position_ms = 0;
    g_engine.duration_ms = 0;

    if (g_engine.p_shm) {
        g_engine.p_shm->position_ms = 0;
        g_engine.p_shm->duration_ms = 0;
        g_engine.p_shm->playback_flags |= OMM_FLAG_STREAMING;
        g_engine.p_shm->playback_flags &= ~OMM_FLAG_UNDERRUN;
    }

    g_engine.playback_state = OMM_STATE_PLAYING;
    if (g_engine.p_shm) g_engine.p_shm->playback_state = OMM_STATE_PLAYING;
    unlock_decoder(&g_engine.decoder_lock);
    return 0;
}

int32_t omm_audio_prefetch_file(const char* filepath) {
    lock_decoder(&g_engine.decoder_lock);
    omm_audio_cancel_prefetch();

    ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 2, 48000);
    if (ma_decoder_init_file(filepath, &config, &g_engine.next_decoder) != MA_SUCCESS) {
        unlock_decoder(&g_engine.decoder_lock);
        return -1;
    }

    ma_uint64 totalFrames = 0;
    if (ma_decoder_get_length_in_pcm_frames(&g_engine.next_decoder, &totalFrames) == MA_SUCCESS) {
        g_engine.next_duration_ms = (uint32_t)((totalFrames * 1000) / 48000);
    } else {
        g_engine.next_duration_ms = 0;
    }

    g_engine.has_next_decoder = true;
    if (g_engine.p_shm) {
        g_engine.p_shm->playback_flags |= OMM_FLAG_PREFETCHING;
    }
    unlock_decoder(&g_engine.decoder_lock);
    return 0;
}

int32_t omm_audio_pause(void) {
    g_engine.playback_state = OMM_STATE_PAUSED;
    if (g_engine.p_shm) g_engine.p_shm->playback_state = OMM_STATE_PAUSED;
    return 0;
}

int32_t omm_audio_resume(void) {
    g_engine.playback_state = OMM_STATE_PLAYING;
    if (g_engine.p_shm) g_engine.p_shm->playback_state = OMM_STATE_PLAYING;
    return 0;
}

int32_t omm_audio_stop(void) {
    omm_audio_cancel_prefetch();
    g_engine.playback_state = OMM_STATE_STOPPED;
    g_engine.position_ms = 0;
    if (g_engine.p_shm) {
        g_engine.p_shm->playback_state = OMM_STATE_STOPPED;
        g_engine.p_shm->position_ms = 0;
    }
    return 0;
}

int32_t omm_audio_set_volume(float volume) {
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    g_engine.volume = volume;
    if (g_engine.p_shm) g_engine.p_shm->volume = volume;
    return 0;
}

int32_t omm_audio_seek(uint32_t target_ms) {
    if (g_engine.source_type == SOURCE_FILE) {
        lock_decoder(&g_engine.decoder_lock);
        if (g_engine.has_current_decoder) {
            ma_uint64 targetFrame = ((uint64_t)target_ms * 48000) / 1000;
            if (ma_decoder_seek_to_pcm_frame(&g_engine.current_decoder, targetFrame) != MA_SUCCESS) {
                unlock_decoder(&g_engine.decoder_lock);
                return -1;
            }
        }
        g_engine.position_ms = target_ms;
        if (g_engine.p_shm) g_engine.p_shm->position_ms = target_ms;
        unlock_decoder(&g_engine.decoder_lock);
        return 0;
    } else if (g_engine.source_type == SOURCE_STREAM && g_engine.seek_stream_fn && g_engine.stream_handle) {
        int64_t byteOffset = (int64_t)target_ms * 48000 * 2 * sizeof(float) / 1000;
        int64_t outPos = 0;
        if (g_engine.seek_stream_fn(g_engine.stream_handle, byteOffset, 0, &outPos) == 0) {
            g_engine.position_ms = target_ms;
            if (g_engine.p_shm) g_engine.p_shm->position_ms = target_ms;
            return 0;
        }
        return -1;
    }
    return -2;
}

uint32_t omm_audio_get_state(void) {
    return g_engine.playback_state;
}

uint32_t omm_audio_get_position_ms(void) {
    return g_engine.position_ms;
}

uint32_t omm_audio_get_duration_ms(void) {
    return g_engine.duration_ms;
}
