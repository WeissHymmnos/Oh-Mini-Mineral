#ifndef OMM_ABI_H
#define OMM_ABI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Magic Identifiers & Protocol Constants */
#define OMM_PACKET_MAGIC            0x4F4D4D50 /* "OMMP" */
#define OMM_SHM_MAGIC               0x4F4D4D53 /* "OMMS" */
#define OMM_TRACK_MAGIC             0x4F4D4D4C /* "OMML" */
#define OMM_PLUGIN_PROTOCOL_VERSION 0x00010000 /* Version 1.0 */

#define OMM_PACKET_SIZE             512
#define OMM_SHM_SIZE                65536
#define OMM_TRACK_SIZE              512
#define OMM_SPECTRUM_BANDS          64

/* Request Opcodes (0x0001 - 0x00FF) */
#define OP_REQ_PING                 0x0001
#define OP_REQ_GET_STATUS           0x0002
#define OP_REQ_PLAY                 0x0003
#define OP_REQ_PAUSE                0x0004
#define OP_REQ_RESUME               0x0005
#define OP_REQ_STOP                 0x0006
#define OP_REQ_SEEK                 0x0007
#define OP_REQ_SET_VOLUME           0x0008
#define OP_REQ_PLAY_URI             0x0009
#define OP_REQ_PLAY_TRACK_ID        0x000A
#define OP_REQ_VIEWPORT             0x0010
#define OP_REQ_QUERY_SIMILAR        0x0011
#define OP_REQ_RESCAN_LIBRARY       0x0012
#define OP_REQ_PLUGIN_WAKE          0x0020
#define OP_REQ_PLUGIN_SUSPEND       0x0021
#define OP_REQ_PLUGIN_UNLOAD        0x0022
#define OP_REQ_GET_LYRICS           0x0030

/* Response Opcodes (0x8001 - 0x80FF) */
#define OP_RESP_PONG                0x8001
#define OP_RESP_STATUS              0x8002
#define OP_RESP_OK                  0x8003
#define OP_RESP_ERROR               0x8004
#define OP_RESP_VIEWPORT_HEADER     0x8010
#define OP_RESP_VIEWPORT_ITEM       0x8011
#define OP_RESP_SIMILAR_HEADER      0x8012
#define OP_RESP_SIMILAR_ITEM        0x8013
#define OP_RESP_LYRICS_LINE         0x8030

/* Audio Format Tags */
#define OMM_FORMAT_UNKNOWN          0
#define OMM_FORMAT_FLAC             1
#define OMM_FORMAT_MP3              2
#define OMM_FORMAT_OGG              3
#define OMM_FORMAT_WAV              4
#define OMM_FORMAT_AAC              5

/* Playback States */
#define OMM_STATE_STOPPED           0
#define OMM_STATE_PLAYING           1
#define OMM_STATE_PAUSED            2
#define OMM_STATE_BUFFERING         3
#define OMM_STATE_ERROR             4

/* Playback Flags */
#define OMM_FLAG_MUTED              0x0001
#define OMM_FLAG_PREFETCHING        0x0002
#define OMM_FLAG_UNDERRUN           0x0004
#define OMM_FLAG_STREAMING          0x0008

/* Plugin Lifecycle States */
#define OMM_PLUGIN_UNLOADED         0
#define OMM_PLUGIN_LAZY_WAKEUP      1
#define OMM_PLUGIN_ACTIVE           2
#define OMM_PLUGIN_SUSPENDED        3
#define OMM_PLUGIN_DEEP_UNLOAD      4

/* 480-byte condensed track record for viewport responses */
typedef struct __attribute__((packed)) {
    uint32_t track_id;
    uint32_t duration_ms;
    uint16_t year;
    uint16_t track_no;
    uint16_t bitrate_kbps;
    uint16_t format_tag; /* 1=FLAC, 2=MP3, 3=OGG, 4=WAV, 5=AAC */
    char title[128];
    char artist[96];
    char album[96];
    char uri[144];
} omm_condensed_track_t;

/* 496-byte packet payload union */
typedef union __attribute__((packed)) {
    uint8_t raw[496];
    uint32_t target_ms;
    float volume;
    char uri[480];
    uint32_t track_id;
    struct __attribute__((packed)) {
        uint32_t offset;
        uint32_t limit;
        uint16_t filter_len;
        char filter_text[126];
    } viewport_req;
    struct __attribute__((packed)) {
        uint32_t total_tracks;
        uint32_t filtered_tracks;
        uint32_t page_offset;
        uint32_t returned_count;
    } viewport_hdr;
    struct __attribute__((packed)) {
        omm_condensed_track_t track_item;
        uint8_t reserved[16];
    } viewport_item;
    struct __attribute__((packed)) {
        uint32_t query_track_id;
        uint32_t query_limit;
    } similar_req;
    struct __attribute__((packed)) {
        uint32_t track_id;
        uint32_t returned_count;
    } similar_hdr;
    struct __attribute__((packed)) {
        float similar_score;
        omm_condensed_track_t similar_track;
        uint8_t reserved[12];
    } similar_item;
    struct __attribute__((packed)) {
        int32_t error_code;
        char error_message[256];
    } error_resp;
} omm_packet_payload_t;

/* 512-byte fixed UDS packet */
typedef struct __attribute__((packed, aligned(8))) {
    uint32_t magic;               /* 0x4F4D4D50 ("OMMP") */
    uint16_t version;             /* Protocol Version (1) */
    uint16_t opcode;              /* OP_REQ_* / OP_RESP_* */
    uint32_t seq_id;              /* Sequence ID */
    int32_t status_code;          /* Status (0=Success, <0=Error) */
    omm_packet_payload_t payload; /* 496-byte payload union */
} omm_packet_t;

/* 65,536-byte (64KB) Shared Memory Segment */
typedef struct __attribute__((packed, aligned(8))) {
    /* 0x0000 - 0x000F: Header & Atomic Seqlock */
    uint32_t magic;                  /* 0x0000: 0x4F4D4D53 ("OMMS") */
    uint32_t version;                /* 0x0004: Version 1 */
    uint64_t seqlock;                /* 0x0008: Atomic sequence lock */

    /* 0x0010 - 0x0027: Playback State */
    uint32_t playback_state;         /* 0x0010: 0=Stopped, 1=Playing, 2=Paused, 3=Buffering, 4=Error */
    uint32_t playback_flags;         /* 0x0014: Bitmask: Muted, Prefetch, Underrun, Streaming */
    uint32_t current_track_id;       /* 0x0018: Active track ID in library */
    uint32_t position_ms;            /* 0x001C: Playback position */
    uint32_t duration_ms;            /* 0x0020: Total track duration */
    float volume;                    /* 0x0024: Volume (0.0 .. 1.0) */

    /* 0x0028 - 0x0037: Audio Metrics */
    uint32_t sample_rate;            /* 0x0028: Audio sample rate */
    uint16_t channels;               /* 0x002C: Channel count (1=Mono, 2=Stereo) */
    uint16_t bit_depth;              /* 0x002E: Bits per sample */
    float buffer_fill_ratio;         /* 0x0030: Ring buffer fill ratio */
    uint32_t underrun_counter;       /* 0x0034: Underrun occurrences */

    /* 0x0038 - 0x004F: Plugin Lifecycle & Daemon Status */
    uint32_t plugin_state;           /* 0x0038: 0=Unloaded, 1=Wakeup, 2=Active, 3=Suspend, 4=DeepUnload */
    uint32_t plugin_idle_secs;       /* 0x003C: Seconds idle */
    uint64_t plugin_rss_bytes;       /* 0x0040: Dynamic plugin RSS bytes */
    uint32_t daemon_pid;             /* 0x0048: PID of host daemon */
    uint32_t daemon_uptime_secs;     /* 0x004C: Daemon uptime in seconds */

    /* 0x0050 - 0x007F: Library Summary & Padding */
    uint32_t total_tracks;           /* 0x0050: Total library track count */
    uint8_t reserved_header[44];     /* 0x0054: Padding to 0x0080 */

    /* 0x0080 - 0x01FF: Track Metadata Strings (UTF-8, Null-terminated) */
    char track_title[128];           /* 0x0080: Null-terminated UTF-8 title */
    char track_artist[128];          /* 0x0100: Null-terminated UTF-8 artist */
    char track_album[128];           /* 0x0180: Null-terminated UTF-8 album */

    /* 0x0200 - 0x02FF: Active Virtual URI */
    char virtual_uri[256];           /* 0x0200: Virtual URI ('file://...' or 'mineral://...') */

    /* 0x0300 - 0x05FF: Synchronized Lyrics */
    char lyric_current[256];         /* 0x0300: Current lyric line */
    char lyric_next[256];            /* 0x0400: Next lyric line */
    char lyric_translation[256];     /* 0x0500: Translated lyric line */

    /* 0x0600 - 0x06FF: Lyric Timing & Reserved */
    uint32_t lyric_timestamp_ms;     /* 0x0600: Lyric timestamp ms */
    uint32_t lyric_line_idx;         /* 0x0604: Active lyric index */
    uint8_t reserved_lyric[248];     /* 0x0608: Padding to 0x0700 */

    /* 0x0700 - 0x07FF: Spectrum Configuration */
    uint32_t spectrum_bands;         /* 0x0700: Spectrum bands (64) */
    uint32_t spectrum_seq;           /* 0x0704: Refresh frame sequence */
    uint8_t reserved_spec[248];      /* 0x0708: Padding to 0x0800 */

    /* 0x0800 - 0x0AFF: 64-Band Spectrum Data */
    float spectrum_mags[64];         /* 0x0800: Normalized magnitudes (0.0..1.0) */
    float spectrum_peaks[64];        /* 0x0900: Peak-hold magnitudes */
    uint8_t quantized_bars[64];      /* 0x0A00: Quantized bar heights (0..64) */
    uint8_t quantized_peaks[64];     /* 0x0A40: Quantized peak heights */
    uint8_t reserved_pad[128];       /* 0x0A80: Padding to 0x0B00 */

    /* 0x0B00 - 0xFFFF: Waveform Tap & Reserved */
    float oscilloscope_tap[512];     /* 0x0B00: PCM waveform oscilloscope tap (2048 B) */
    uint8_t reserved_payload[60672]; /* 0x1300: Reserved segment payload (pad to 65536) */
} omm_shm_t;

/* 512-byte sector-aligned binary track record (library.bin) */
typedef struct __attribute__((packed, aligned(512))) {
    uint32_t track_id;               /* 4 B: Unique track ID */
    uint32_t duration_ms;            /* 4 B: Duration in ms */
    uint16_t year;                   /* 2 B: Release year */
    uint16_t track_no;               /* 2 B: Track number */
    uint16_t bitrate_kbps;           /* 2 B: Bitrate */
    uint16_t format_tag;             /* 2 B: 1=FLAC, 2=MP3, 3=OGG, 4=WAV, 5=AAC */
    char title[128];                 /* 128 B: UTF-8 Title */
    char artist[96];                 /* 96 B: UTF-8 Artist */
    char album[96];                  /* 96 B: UTF-8 Album */
    char relative_path[128];         /* 128 B: Relative file path */
    int8_t tfidf_vector[32];         /* 32 B: 32-dim quantized TF-IDF vector */
    float vector_norm;               /* 4 B: Precomputed Euclidean L2 norm */
    uint8_t reserved[12];            /* 12 B: Padding to exactly 512 bytes */
} omm_track_record_t;

/* Plugin Status */
typedef struct {
    uint32_t protocol_version;
    uint32_t state;                  /* 0=Unloaded, 1=Wakeup, 2=Active, 3=Suspend, 4=DeepUnload */
    uint64_t rss_bytes;              /* Dynamic RSS memory footprint */
    uint32_t active_streams;         /* Open stream handles */
    uint32_t idle_seconds;           /* Seconds since last I/O */
} OmmPluginStatus;

/* Opaque stream handle */
typedef void* OmmStreamHandle;

/* Plugin C-ABI VTable */
typedef struct {
    uint32_t protocol_version;
    
    int32_t (*init)(const char* config_path);
    int32_t (*shutdown)(void);
    int32_t (*get_status)(OmmPluginStatus* out_status);
    int32_t (*suspend)(void);
    int32_t (*resume)(void);
    
    int32_t (*can_handle)(const char* uri);
    int32_t (*open_stream)(const char* uri, OmmStreamHandle* out_handle);
    int32_t (*read_stream)(OmmStreamHandle handle, uint8_t* buffer, size_t count, size_t* out_read);
    int32_t (*seek_stream)(OmmStreamHandle handle, int64_t offset, int32_t whence, int64_t* out_pos);
    int32_t (*close_stream)(OmmStreamHandle handle);
    
    int32_t (*fetch_lyrics)(const char* uri, char* out_buf, size_t buf_len, size_t* out_len);
} OmmPluginVTable;

/* Dynamic entry point signature */
typedef const OmmPluginVTable* (*omm_plugin_get_vtable_fn)(uint32_t protocol_version);

/* Standard Error Codes */
typedef enum {
    OMM_OK                     =  0,
    OMM_ERR_GENERIC            = -1,
    OMM_ERR_INVALID_PARAM      = -2,
    OMM_ERR_BUFFER_TOO_SMALL   = -3,
    OMM_ERR_UNSUPPORTED_URI    = -4,
    OMM_ERR_NETWORK_FAILURE    = -5,
    OMM_ERR_STREAM_EOF         = -6,
    OMM_ERR_STREAM_TIMEOUT     = -7,
    OMM_ERR_SUSPENDED          = -8,
    OMM_ERR_AUTH_REQUIRED      = -9,
    OMM_ERR_DECODE_FAILURE     = -10,
    OMM_ERR_PANIC              = -999
} OmmErrorCode;

#ifdef __cplusplus
}
#endif

#endif /* OMM_ABI_H */
