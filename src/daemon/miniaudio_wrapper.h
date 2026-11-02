#ifndef MINIAUDIO_WRAPPER_H
#define MINIAUDIO_WRAPPER_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "../common/omm_abi.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Stream reader and seeker function types matching C-ABI VTable */
typedef int32_t (*omm_stream_read_fn)(void* stream_handle, uint8_t* buffer, size_t count, size_t* out_read);
typedef int32_t (*omm_stream_seek_fn)(void* stream_handle, int64_t offset, int32_t whence, int64_t* out_pos);

/* Initialization & Lifecycle */
int32_t omm_audio_init(omm_shm_t* shm);
void    omm_audio_uninit(void);

/* Playback Control */
int32_t omm_audio_play_file(const char* filepath);
int32_t omm_audio_play_stream(void* stream_handle, omm_stream_read_fn read_fn, omm_stream_seek_fn seek_fn);
int32_t omm_audio_pause(void);
int32_t omm_audio_resume(void);
int32_t omm_audio_stop(void);
int32_t omm_audio_seek(uint32_t target_ms);
int32_t omm_audio_set_volume(float volume);

/* Gapless Prefetch */
int32_t omm_audio_prefetch_file(const char* filepath);
int32_t omm_audio_cancel_prefetch(void);

/* Status Accessors */
uint32_t omm_audio_get_state(void);
uint32_t omm_audio_get_position_ms(void);
uint32_t omm_audio_get_duration_ms(void);

#ifdef __cplusplus
}
#endif

#endif /* MINIAUDIO_WRAPPER_H */
