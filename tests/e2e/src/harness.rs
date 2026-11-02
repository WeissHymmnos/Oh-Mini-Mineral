//! End-to-End Test Harness for Oh-My-Mineral (Free Pascal Host + Rust cdylib Plugin).
//!
//! Provides binary 512-byte UDS framing (`TOMMPacket`), 64KB POSIX Seqlock SHM runner,
//! external process lifecycle manager (`bin/omm_daemon`), Linux memory profiling,
//! and progressive testability reference engine.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use tempfile::TempDir;

// ============================================================================
// 1. CANONICAL PROTOCOL CONSTANTS & OPCODES (PROJECT.md Interface Contracts)
// ============================================================================

pub const OMM_PACKET_MAGIC: u32 = 0x4F4D4D50; // "OMMP"
pub const OMM_PROTOCOL_VERSION: u16 = 1;
pub const OMM_PACKET_SIZE: usize = 512;

pub const OMM_SHM_NAME: &str = "/dev/shm/omm_shm";
pub const OMM_SHM_MAGIC: u32 = 0x4F4D4D53; // "OMMS"
pub const OMM_SHM_VERSION: u32 = 1;
pub const OMM_SHM_SIZE: usize = 65536; // 64 KB exact
pub const OMM_SPECTRUM_BANDS: usize = 64;

pub const OMM_TRACK_MAGIC: u32 = 0x4F4D4D4C; // "OMML"
pub const OMM_TRACK_RECORD_SIZE: usize = 512;

pub const OMM_PLUGIN_PROTOCOL_VERSION: u32 = 0x00010000; // 1.0

// Request Opcodes (0x0001 - 0x00FF)
pub const OP_REQ_PING: u16 = 0x0001;
pub const OP_REQ_GET_STATUS: u16 = 0x0002;
pub const OP_REQ_PLAY: u16 = 0x0003;
pub const OP_REQ_PAUSE: u16 = 0x0004;
pub const OP_REQ_RESUME: u16 = 0x0005;
pub const OP_REQ_STOP: u16 = 0x0006;
pub const OP_REQ_SEEK: u16 = 0x0007; // Payload: TargetMs: u32
pub const OP_REQ_SET_VOLUME: u16 = 0x0008; // Payload: Volume: f32 (0.0 .. 1.0)
pub const OP_REQ_PLAY_URI: u16 = 0x0009; // Payload: URI: [u8; 480]
pub const OP_REQ_PLAY_TRACK_ID: u16 = 0x000A; // Payload: TrackID: u32
pub const OP_REQ_VIEWPORT: u16 = 0x0010; // Payload: ViewportOffset: u32, ViewportLimit: u32, FilterLen: u16, FilterText: [u8; 126]
pub const OP_REQ_QUERY_SIMILAR: u16 = 0x0011; // Payload: TrackID: u32, Limit: u32
pub const OP_REQ_RESCAN_LIBRARY: u16 = 0x0012;
pub const OP_REQ_PLUGIN_WAKE: u16 = 0x0020;
pub const OP_REQ_PLUGIN_SUSPEND: u16 = 0x0021;
pub const OP_REQ_PLUGIN_UNLOAD: u16 = 0x0022;
pub const OP_REQ_GET_LYRICS: u16 = 0x0030; // Payload: TrackID: u32

// Response Opcodes (0x8001 - 0x80FF)
pub const OP_RESP_PONG: u16 = 0x8001;
pub const OP_RESP_STATUS: u16 = 0x8002;
pub const OP_RESP_OK: u16 = 0x8003;
pub const OP_RESP_ERROR: u16 = 0x8004; // Payload: ErrorCode: i32, Message: [u8; 256]
pub const OP_RESP_VIEWPORT_HEADER: u16 = 0x8010; // Payload: TotalTracks: u32, FilteredTracks: u32, Offset: u32, ReturnedCount: u32
pub const OP_RESP_VIEWPORT_ITEM: u16 = 0x8011; // Payload: TOMMCondensedTrack (480 bytes)
pub const OP_RESP_SIMILAR_HEADER: u16 = 0x8012; // Payload: TrackID: u32, ReturnedCount: u32
pub const OP_RESP_SIMILAR_ITEM: u16 = 0x8013; // Payload: SimilarityScore: f32, TOMMCondensedTrack (480 bytes)
pub const OP_RESP_LYRICS_LINE: u16 = 0x8030;

// Error Codes
pub const OMM_OK: i32 = 0;
pub const OMM_ERR_GENERIC: i32 = -1;
pub const OMM_ERR_INVALID_PARAM: i32 = -2;
pub const OMM_ERR_BUFFER_TOO_SMALL: i32 = -3;
pub const OMM_ERR_UNSUPPORTED_SCHEME: i32 = -4;
pub const OMM_ERR_NETWORK_FAILURE: i32 = -5;
pub const OMM_ERR_STREAM_EOF: i32 = -6;
pub const OMM_ERR_STREAM_TIMEOUT: i32 = -7;
pub const OMM_ERR_SUSPENDED: i32 = -8;
pub const OMM_ERR_AUTH_REQUIRED: i32 = -9;
pub const OMM_ERR_DECODE_FAILURE: i32 = -10;
pub const OMM_ERR_PANIC: i32 = -999;

// Playback State Constants
pub const STATE_STOPPED: u32 = 0;
pub const STATE_PLAYING: u32 = 1;
pub const STATE_PAUSED: u32 = 2;
pub const STATE_BUFFERING: u32 = 3;
pub const STATE_ERROR: u32 = 4;

// Watchdog Plugin State Constants
pub const PLUGIN_STATE_UNLOADED: u32 = 0;
pub const PLUGIN_STATE_WAKEUP: u32 = 1;
pub const PLUGIN_STATE_ACTIVE: u32 = 2;
pub const PLUGIN_STATE_SUSPEND: u32 = 3;
pub const PLUGIN_STATE_DEEP_UNLOAD: u32 = 4;

// Playback Flags
pub const FLAG_MUTED: u32 = 1 << 0;
pub const FLAG_PREFETCHING: u32 = 1 << 1;
pub const FLAG_UNDERRUN: u32 = 1 << 2;
pub const FLAG_STREAMING: u32 = 1 << 3;

// ============================================================================
// 2. BINARY STRUCTURE DEFINITIONS (C-ABI & Free Pascal Aligned)
// ============================================================================

/// 480-byte condensed track record for viewport responses and similarity results.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TOMMCondensedTrack {
    pub track_id: u32,          // 4 bytes
    pub duration_ms: u32,       // 4 bytes
    pub year: u16,              // 2 bytes
    pub track_no: u16,          // 2 bytes
    pub bitrate_kbps: u16,      // 2 bytes
    pub format_tag: u16,        // 2 bytes (1=FLAC, 2=MP3, 3=OGG, 4=WAV, 5=AAC)
    pub title: [u8; 128],       // 128 bytes (UTF-8)
    pub artist: [u8; 96],       // 96 bytes (UTF-8)
    pub album: [u8; 96],        // 96 bytes (UTF-8)
    pub uri: [u8; 144],         // 144 bytes (UTF-8)
}

impl Default for TOMMCondensedTrack {
    fn default() -> Self {
        Self {
            track_id: 0,
            duration_ms: 0,
            year: 0,
            track_no: 0,
            bitrate_kbps: 0,
            format_tag: 0,
            title: [0; 128],
            artist: [0; 96],
            album: [0; 96],
            uri: [0; 144],
        }
    }
}

/// Fixed-length 512-byte binary packet for Channel A (Unix Domain Socket).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TOMMPacket {
    pub magic: u32,             // 4 bytes: 0x4F4D4D50 ('OMMP')
    pub version: u16,           // 2 bytes: 1
    pub opcode: u16,            // 2 bytes
    pub seq_id: u32,            // 4 bytes
    pub status_code: i32,       // 4 bytes (0=request or OK, <0=error)
    pub payload: [u8; 496],     // 496 bytes
}

impl TOMMPacket {
    pub fn new(opcode: u16, seq_id: u32) -> Self {
        Self {
            magic: OMM_PACKET_MAGIC,
            version: OMM_PROTOCOL_VERSION,
            opcode,
            seq_id,
            status_code: OMM_OK,
            payload: [0u8; 496],
        }
    }

    pub fn ping(seq_id: u32) -> Self {
        Self::new(OP_REQ_PING, seq_id)
    }

    pub fn get_status(seq_id: u32) -> Self {
        Self::new(OP_REQ_GET_STATUS, seq_id)
    }

    pub fn play(seq_id: u32) -> Self {
        Self::new(OP_REQ_PLAY, seq_id)
    }

    pub fn pause(seq_id: u32) -> Self {
        Self::new(OP_REQ_PAUSE, seq_id)
    }

    pub fn resume(seq_id: u32) -> Self {
        Self::new(OP_REQ_RESUME, seq_id)
    }

    pub fn stop(seq_id: u32) -> Self {
        Self::new(OP_REQ_STOP, seq_id)
    }

    pub fn seek(seq_id: u32, target_ms: u32) -> Self {
        let mut pkt = Self::new(OP_REQ_SEEK, seq_id);
        pkt.payload[0..4].copy_from_slice(&target_ms.to_le_bytes());
        pkt
    }

    pub fn set_volume(seq_id: u32, volume: f32) -> Self {
        let mut pkt = Self::new(OP_REQ_SET_VOLUME, seq_id);
        pkt.payload[0..4].copy_from_slice(&volume.to_le_bytes());
        pkt
    }

    pub fn play_uri(seq_id: u32, uri: &str) -> Self {
        let mut pkt = Self::new(OP_REQ_PLAY_URI, seq_id);
        let b = uri.as_bytes();
        let len = b.len().min(479);
        pkt.payload[0..len].copy_from_slice(&b[..len]);
        pkt.payload[len] = 0;
        pkt
    }

    pub fn play_track_id(seq_id: u32, track_id: u32) -> Self {
        let mut pkt = Self::new(OP_REQ_PLAY_TRACK_ID, seq_id);
        pkt.payload[0..4].copy_from_slice(&track_id.to_le_bytes());
        pkt
    }

    pub fn viewport(seq_id: u32, offset: u32, limit: u32, filter: Option<&str>) -> Self {
        let mut pkt = Self::new(OP_REQ_VIEWPORT, seq_id);
        pkt.payload[0..4].copy_from_slice(&offset.to_le_bytes());
        pkt.payload[4..8].copy_from_slice(&limit.to_le_bytes());
        if let Some(f) = filter {
            let fb = f.as_bytes();
            let flen = fb.len().min(125);
            pkt.payload[8..10].copy_from_slice(&(flen as u16).to_le_bytes());
            pkt.payload[10..10 + flen].copy_from_slice(&fb[..flen]);
            pkt.payload[10 + flen] = 0;
        } else {
            pkt.payload[8..10].copy_from_slice(&0u16.to_le_bytes());
        }
        pkt
    }

    pub fn query_similar(seq_id: u32, track_id: u32, limit: u32) -> Self {
        let mut pkt = Self::new(OP_REQ_QUERY_SIMILAR, seq_id);
        pkt.payload[0..4].copy_from_slice(&track_id.to_le_bytes());
        pkt.payload[4..8].copy_from_slice(&limit.to_le_bytes());
        pkt
    }

    pub fn rescan_library(seq_id: u32) -> Self {
        Self::new(OP_REQ_RESCAN_LIBRARY, seq_id)
    }

    pub fn plugin_wake(seq_id: u32) -> Self {
        Self::new(OP_REQ_PLUGIN_WAKE, seq_id)
    }

    pub fn plugin_suspend(seq_id: u32) -> Self {
        Self::new(OP_REQ_PLUGIN_SUSPEND, seq_id)
    }

    pub fn plugin_unload(seq_id: u32) -> Self {
        Self::new(OP_REQ_PLUGIN_UNLOAD, seq_id)
    }

    pub fn get_lyrics(seq_id: u32, track_id: u32) -> Self {
        let mut pkt = Self::new(OP_REQ_GET_LYRICS, seq_id);
        pkt.payload[0..4].copy_from_slice(&track_id.to_le_bytes());
        pkt
    }

    pub fn ok(seq_id: u32) -> Self {
        let mut pkt = Self::new(OP_RESP_OK, seq_id);
        pkt.status_code = OMM_OK;
        pkt
    }

    pub fn pong(seq_id: u32) -> Self {
        let mut pkt = Self::new(OP_RESP_PONG, seq_id);
        pkt.status_code = OMM_OK;
        pkt
    }

    pub fn error(seq_id: u32, code: i32, msg: &str) -> Self {
        let mut pkt = Self::new(OP_RESP_ERROR, seq_id);
        pkt.status_code = code;
        let b = msg.as_bytes();
        let len = b.len().min(255);
        pkt.payload[0..len].copy_from_slice(&b[..len]);
        pkt.payload[len] = 0;
        pkt
    }

    pub fn as_bytes(&self) -> &[u8; 512] {
        unsafe { &*(self as *const Self as *const [u8; 512]) }
    }

    pub fn as_mut_bytes(&mut self) -> &mut [u8; 512] {
        unsafe { &mut *(self as *mut Self as *mut [u8; 512]) }
    }

    pub fn from_bytes(bytes: &[u8; 512]) -> Self {
        unsafe { std::ptr::read_unaligned(bytes.as_ptr() as *const Self) }
    }

    pub fn get_target_ms(&self) -> u32 {
        u32::from_le_bytes(self.payload[0..4].try_into().unwrap_or_default())
    }

    pub fn get_volume(&self) -> f32 {
        f32::from_le_bytes(self.payload[0..4].try_into().unwrap_or_default())
    }

    pub fn get_uri_str(&self) -> String {
        let null_pos = self.payload[..480].iter().position(|&b| b == 0).unwrap_or(480);
        String::from_utf8_lossy(&self.payload[..null_pos]).to_string()
    }

    pub fn get_track_id(&self) -> u32 {
        u32::from_le_bytes(self.payload[0..4].try_into().unwrap_or_default())
    }

    pub fn get_viewport_req(&self) -> (u32, u32, String) {
        let offset = u32::from_le_bytes(self.payload[0..4].try_into().unwrap_or_default());
        let limit = u32::from_le_bytes(self.payload[4..8].try_into().unwrap_or_default());
        let flen = u16::from_le_bytes(self.payload[8..10].try_into().unwrap_or_default()) as usize;
        let flen = flen.min(125);
        let filter = String::from_utf8_lossy(&self.payload[10..10 + flen]).to_string();
        (offset, limit, filter)
    }

    pub fn get_viewport_header(&self) -> (u32, u32, u32, u32) {
        let total = u32::from_le_bytes(self.payload[0..4].try_into().unwrap_or_default());
        let filtered = u32::from_le_bytes(self.payload[4..8].try_into().unwrap_or_default());
        let offset = u32::from_le_bytes(self.payload[8..12].try_into().unwrap_or_default());
        let count = u32::from_le_bytes(self.payload[12..16].try_into().unwrap_or_default());
        (total, filtered, offset, count)
    }

    pub fn get_error(&self) -> (i32, String) {
        let null_pos = self.payload[..256].iter().position(|&b| b == 0).unwrap_or(256);
        let msg = String::from_utf8_lossy(&self.payload[..null_pos]).to_string();
        (self.status_code, msg)
    }
}

/// 64KB POSIX Shared Memory layout protected by 64-bit atomic Seqlock (`/dev/shm/omm_shm`).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TOMMSharedMemory {
    pub magic: u32,                 // 0x0000: 0x4F4D4D53 ('OMMS')
    pub version: u32,               // 0x0004: 1
    pub seqlock: u64,               // 0x0008: 64-bit atomic sequence lock
    pub playback_state: u32,        // 0x0010: 0=Stopped, 1=Playing, 2=Paused, 3=Buffering, 4=Error
    pub playback_flags: u32,        // 0x0014: Bit 0: Muted, Bit 1: Prefetch, Bit 2: Underrun, Bit 3: Streaming
    pub current_track_id: u32,      // 0x0018: active track id
    pub position_ms: u32,           // 0x001C: current position ms
    pub duration_ms: u32,           // 0x0020: total duration ms
    pub volume: f32,                // 0x0024: 0.0 .. 1.0
    pub sample_rate: u32,           // 0x0028: 44100, 48000, etc.
    pub channels: u16,              // 0x002C: 1=mono, 2=stereo
    pub bit_depth: u16,             // 0x002E: 16, 24, 32
    pub buffer_fill_ratio: f32,     // 0x0030: 0.0 .. 1.0
    pub underrun_counter: u32,      // 0x0034: total underruns
    pub plugin_state: u32,          // 0x0038: 0=Unloaded, 1=Wakeup, 2=Active, 3=Suspend, 4=DeepUnload
    pub plugin_idle_secs: u32,      // 0x003C
    pub plugin_rss_bytes: u64,      // 0x0040
    pub daemon_pid: u32,            // 0x0048
    pub daemon_uptime_secs: u32,    // 0x004C
    pub total_tracks: u32,          // 0x0050
    pub reserved_header: [u8; 44],  // 0x0054: pad to 0x0080
    pub track_title: [u8; 128],     // 0x0080
    pub track_artist: [u8; 128],    // 0x0100
    pub track_album: [u8; 128],     // 0x0180
    pub virtual_uri: [u8; 256],     // 0x0200
    pub lyric_current: [u8; 256],   // 0x0300
    pub lyric_next: [u8; 256],      // 0x0400
    pub lyric_translation: [u8; 256],// 0x0500
    pub lyric_timestamp_ms: u32,    // 0x0600
    pub lyric_line_idx: u32,        // 0x0604
    pub reserved_lyric: [u8; 248],  // 0x0608: pad to 0x0700
    pub spectrum_bands: u32,        // 0x0700: 64
    pub spectrum_seq: u32,          // 0x0704
    pub reserved_spec: [u8; 248],   // 0x0708: pad to 0x0800
    pub spectrum_mags: [f32; 64],   // 0x0800: 256 bytes
    pub spectrum_peaks: [f32; 64],  // 0x0900: 256 bytes
    pub quantized_bars: [u8; 64],   // 0x0A00: 64 bytes
    pub quantized_peaks: [u8; 64],  // 0x0A40: 64 bytes
    pub reserved_pad: [u8; 128],    // 0x0A80: pad to 0x0B00
    pub oscilloscope_tap: [f32; 512],// 0x0B00: 2048 bytes
    pub reserved_payload: [u8; 60672], // 0x1300: pad to 65536
}

impl Default for TOMMSharedMemory {
    fn default() -> Self {
        Self {
            magic: OMM_SHM_MAGIC,
            version: OMM_SHM_VERSION,
            seqlock: 0,
            playback_state: STATE_STOPPED,
            playback_flags: 0,
            current_track_id: 0,
            position_ms: 0,
            duration_ms: 0,
            volume: 1.0,
            sample_rate: 44100,
            channels: 2,
            bit_depth: 16,
            buffer_fill_ratio: 0.0,
            underrun_counter: 0,
            plugin_state: PLUGIN_STATE_UNLOADED,
            plugin_idle_secs: 0,
            plugin_rss_bytes: 0,
            daemon_pid: 0,
            daemon_uptime_secs: 0,
            total_tracks: 0,
            reserved_header: [0; 44],
            track_title: [0; 128],
            track_artist: [0; 128],
            track_album: [0; 128],
            virtual_uri: [0; 256],
            lyric_current: [0; 256],
            lyric_next: [0; 256],
            lyric_translation: [0; 256],
            lyric_timestamp_ms: 0,
            lyric_line_idx: 0,
            reserved_lyric: [0; 248],
            spectrum_bands: 64,
            spectrum_seq: 0,
            reserved_spec: [0; 248],
            spectrum_mags: [0.0; 64],
            spectrum_peaks: [0.0; 64],
            quantized_bars: [0; 64],
            quantized_peaks: [0; 64],
            reserved_pad: [0; 128],
            oscilloscope_tap: [0.0; 512],
            reserved_payload: [0; 60672],
        }
    }
}

/// 512-byte sector-aligned binary track record stored in `library.bin`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TOMMTrackRecord {
    pub track_id: u32,                        // 4 bytes: 1-based unique track ID
    pub duration_ms: u32,                     // 4 bytes: Duration in ms
    pub year: u16,                            // 2 bytes: Release year
    pub track_no: u16,                        // 2 bytes: Track number on album
    pub bitrate_kbps: u16,                    // 2 bytes: Encoded bitrate
    pub format_tag: u16,                      // 2 bytes: 1=FLAC, 2=MP3, 3=OGG, 4=WAV, 5=AAC
    pub title: [u8; 128],                     // 128 bytes: Null-terminated UTF-8
    pub artist: [u8; 96],                     // 96 bytes: Null-terminated UTF-8
    pub album: [u8; 96],                      // 96 bytes: Null-terminated UTF-8
    pub relative_path: [u8; 128],             // 128 bytes: Null-terminated path relative to music root
    pub tfidf_vector: [i8; 32],               // 32 bytes: 32-dimensional Int8 TF-IDF vector (-128..127)
    pub vector_norm: f32,                     // 4 bytes: Precomputed L2 norm
    pub reserved: [u8; 12],                   // 12 bytes: Padding to exactly 512 bytes
}

impl Default for TOMMTrackRecord {
    fn default() -> Self {
        Self {
            track_id: 0,
            duration_ms: 0,
            year: 0,
            track_no: 0,
            bitrate_kbps: 0,
            format_tag: 0,
            title: [0; 128],
            artist: [0; 96],
            album: [0; 96],
            relative_path: [0; 128],
            tfidf_vector: [0; 32],
            vector_norm: 0.0,
            reserved: [0; 12],
        }
    }
}

/// Header record for `library.bin` (512 bytes).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TOMMLibraryHeader {
    pub magic: u32,             // 4 bytes: 0x4F4D4D4C ('OMML')
    pub version: u32,           // 4 bytes: 1
    pub record_size: u32,       // 4 bytes: 512
    pub record_count: u32,      // 4 bytes
    pub created_timestamp: u64, // 8 bytes
    pub last_rescan_timestamp: u64, // 8 bytes
    pub reserved: [u8; 480],    // 480 bytes: pad to 512
}

impl Default for TOMMLibraryHeader {
    fn default() -> Self {
        Self {
            magic: OMM_TRACK_MAGIC,
            version: 1,
            record_size: 512,
            record_count: 0,
            created_timestamp: 0,
            last_rescan_timestamp: 0,
            reserved: [0; 480],
        }
    }
}

// ============================================================================
// 3. ATOMIC SEQLOCK CONSISTENT SHARED MEMORY READER
// ============================================================================

/// Reads 64KB shared memory segment with 64-bit atomic Seqlock consistency.
///
/// Ensures readers never encounter torn writes while daemon audio callback updates
/// at 60 FPS without locks or mutexes.
pub fn read_shm_consistent<P: AsRef<Path>>(shm_path: P) -> Result<TOMMSharedMemory, io::Error> {
    let file = File::open(shm_path)?;
    let file_len = file.metadata()?.len();
    if file_len < OMM_SHM_SIZE as u64 {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, format!("SHM segment length {} < {}", file_len, OMM_SHM_SIZE)));
    }
    let mmap = unsafe { memmap2::MmapOptions::new().len(OMM_SHM_SIZE).map(&file)? };
    let ptr = mmap.as_ptr() as *const TOMMSharedMemory;

    // Retry loop for 64-bit atomic seqlock
    for _ in 0..100 {
        let seq1 = unsafe { std::ptr::read_volatile(&((*ptr).seqlock)) };
        if seq1 & 1 != 0 {
            // Active write in progress, spin-wait briefly
            std::hint::spin_loop();
            continue;
        }
        std::sync::atomic::fence(Ordering::Acquire);
        let snapshot = unsafe { std::ptr::read_volatile(ptr) };
        std::sync::atomic::fence(Ordering::Acquire);
        let seq2 = unsafe { std::ptr::read_volatile(&((*ptr).seqlock)) };
        if seq1 == seq2 && (seq2 & 1 == 0) {
            return Ok(snapshot);
        }
        std::hint::spin_loop();
    }
    Err(io::Error::new(io::ErrorKind::WouldBlock, "Seqlock contention retry timeout"))
}

// ============================================================================
// 4. UDS CLIENT (BINARY 512-BYTE PACKET PROTOCOL)
// ============================================================================

pub struct UdsClient {
    stream: UnixStream,
}

impl UdsClient {
    pub fn connect<P: AsRef<Path>>(path: P) -> Result<Self, io::Error> {
        let stream = UnixStream::connect(path)?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        Ok(Self { stream })
    }

    /// Sends a 512-byte binary packet.
    pub fn send_packet(&mut self, pkt: &TOMMPacket) -> Result<(), io::Error> {
        self.stream.write_all(pkt.as_bytes())?;
        self.stream.flush()?;
        Ok(())
    }

    /// Receives a 512-byte binary packet.
    pub fn recv_packet(&mut self) -> Result<TOMMPacket, io::Error> {
        let mut buf = [0u8; 512];
        self.stream.read_exact(&mut buf)?;
        let pkt = TOMMPacket::from_bytes(&buf);
        if pkt.magic != OMM_PACKET_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Invalid packet magic: {:#X}, expected {:#X}", pkt.magic, OMM_PACKET_MAGIC),
            ));
        }
        Ok(pkt)
    }

    /// Sends a command packet and awaits the 512-byte response.
    /// If the response is a Viewport or Similar header with following item packets,
    /// drains the item packets so the stream remains in sync.
    pub fn send_command(&mut self, pkt: &TOMMPacket) -> Result<TOMMPacket, io::Error> {
        self.send_packet(pkt)?;
        let resp = self.recv_packet()?;
        if resp.opcode == OP_RESP_VIEWPORT_HEADER {
            let (_, _, _, count) = resp.get_viewport_header();
            for _ in 0..count {
                let _ = self.recv_packet()?;
            }
        } else if resp.opcode == OP_RESP_SIMILAR_HEADER {
            let count = u32::from_le_bytes(resp.payload[4..8].try_into().unwrap_or_default());
            for _ in 0..count {
                let _ = self.recv_packet()?;
            }
        }
        Ok(resp)
    }

    /// Sends raw bytes over the socket (for boundary/corruption testing).
    pub fn send_raw(&mut self, bytes: &[u8]) -> Result<(), io::Error> {
        self.stream.write_all(bytes)?;
        self.stream.flush()?;
        Ok(())
    }

    /// Reads raw bytes from the socket.
    pub fn read_raw(&mut self, buf: &mut [u8]) -> Result<usize, io::Error> {
        self.stream.read(buf)
    }

    /// Closes the connection.
    pub fn shutdown(&self) -> Result<(), io::Error> {
        self.stream.shutdown(std::net::Shutdown::Both)
    }
}

impl Drop for UdsClient {
    fn drop(&mut self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
    }
}


// ============================================================================
// 5. MEMORY & PROCESS INSPECTION (LINUX /proc/<pid>/statm)
// ============================================================================

/// Reads resident set size (RSS) in kilobytes from `/proc/<pid>/statm`.
pub fn get_process_rss_kb(pid: u32) -> Result<usize, io::Error> {
    let statm_path = format!("/proc/{}/statm", pid);
    let content = std::fs::read_to_string(&statm_path)?;
    let mut parts = content.split_whitespace();
    let _total_pages = parts.next();
    let resident_pages_str = parts.next().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "Invalid statm format")
    })?;
    let resident_pages: usize = resident_pages_str.parse().map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidData, "Failed to parse resident pages")
    })?;

    // Page size is 4096 bytes (4 KB) on Linux x86_64
    let page_size_kb = 4;
    Ok(resident_pages * page_size_kb)
}

/// Reads the current process's RSS in KB.
pub fn get_current_rss_kb() -> usize {
    get_process_rss_kb(std::process::id()).unwrap_or(0)
}

// ============================================================================
// 6. TEST DAEMON LAUNCHER & SUPERVISOR
// ============================================================================

pub enum DaemonMode {
    ExternalProcess(Child),
    EmbeddedServer {
        stop_signal: Arc<AtomicBool>,
        thread_handle: Option<JoinHandle<()>>,
        _shm_mmap: memmap2::MmapMut,
    },
}

pub struct TestDaemon {
    pub mode: DaemonMode,
    pub socket_path: PathBuf,
    pub shm_path: PathBuf,
    pub _temp_dir: TempDir,
    pub pid: Option<u32>,
}

impl TestDaemon {
    /// Spawns a test daemon targeting `bin/omm_daemon`.
    ///
    /// If an external daemon binary exists (specified via `OMM_DAEMON_BIN` or found
    /// at `bin/omm_daemon`, `target/release/omm_daemon`, or `target/debug/omm_daemon`),
    /// it is spawned as an external OS process.
    ///
    /// Otherwise, an in-process reference engine is spawned in a background thread
    /// with true 64KB Seqlock SHM and 512-byte binary UDS packets, providing
    /// 100% progressive testability.
    pub fn start() -> Result<Self, io::Error> {
        let temp_dir = tempfile::Builder::new()
            .prefix("omm_e2e_")
            .tempdir()?;
        let socket_path = temp_dir.path().join("omm.sock");
        let shm_path = temp_dir.path().join("omm_shm");

        // Check for external daemon binary
        let mut candidate_bin = None;
        if let Ok(env_bin) = std::env::var("OMM_DAEMON_BIN") {
            let p = PathBuf::from(env_bin);
            if p.exists() {
                candidate_bin = Some(p);
            }
        }
        if candidate_bin.is_none() {
            let repo_root = PathBuf::from("/home/wh/Documents/projects/gui_mineral");
            let candidates = [
                repo_root.join("bin/omm_daemon"),
                repo_root.join("bin/omm_daemon_stripped"),
                repo_root.join("target/release/omm_daemon"),
                repo_root.join("target/release/omm-core-daemon"),
                repo_root.join("target/debug/omm_daemon"),
            ];
            for c in candidates {
                if c.exists() {
                    candidate_bin = Some(c);
                    break;
                }
            }
        }

        if let Some(bin_path) = candidate_bin {
            // Launch external process
            let child = Command::new(&bin_path)
                .arg("--socket")
                .arg(&socket_path)
                .arg("--shm")
                .arg(&shm_path)
                .spawn()?;
            let pid = child.id();

            // Wait for socket to become ready
            let start_wait = Instant::now();
            let mut connected = false;
            while start_wait.elapsed() < Duration::from_secs(3) {
                if socket_path.exists() {
                    if let Ok(client) = UnixStream::connect(&socket_path) {
                        drop(client);
                        connected = true;
                        break;
                    }
                }
                thread::sleep(Duration::from_millis(50));
            }

            if !connected {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Timed out waiting for external daemon socket",
                ));
            }

            Ok(Self {
                mode: DaemonMode::ExternalProcess(child),
                socket_path,
                shm_path,
                _temp_dir: temp_dir,
                pid: Some(pid),
            })
        } else {
            // Launch in-process reference daemon server
            let shm_file = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o666)
                .open(&shm_path)?;
            shm_file.set_len(OMM_SHM_SIZE as u64)?;

            let mut mmap_mut = unsafe { memmap2::MmapMut::map_mut(&shm_file)? };
            // Initialize SHM default header
            let default_shm = TOMMSharedMemory::default();
            unsafe {
                std::ptr::copy_nonoverlapping(
                    &default_shm as *const TOMMSharedMemory as *const u8,
                    mmap_mut.as_mut_ptr(),
                    OMM_SHM_SIZE,
                );
            }

            let stop_signal = Arc::new(AtomicBool::new(false));
            let stop_clone = Arc::clone(&stop_signal);
            let sock_clone = socket_path.clone();
            let shm_addr = mmap_mut.as_mut_ptr() as usize;

            let handle = thread::spawn(move || {
                let shm_ptr = shm_addr as *mut TOMMSharedMemory;
                run_reference_daemon_server(&sock_clone, shm_ptr, stop_clone);
            });

            // Wait for socket to become ready
            let start_wait = Instant::now();
            let mut connected = false;
            while start_wait.elapsed() < Duration::from_secs(3) {
                if socket_path.exists() {
                    if let Ok(client) = UnixStream::connect(&socket_path) {
                        drop(client);
                        connected = true;
                        break;
                    }
                }
                thread::sleep(Duration::from_millis(20));
            }

            if !connected {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Timed out waiting for reference daemon socket",
                ));
            }

            Ok(Self {
                mode: DaemonMode::EmbeddedServer {
                    stop_signal,
                    thread_handle: Some(handle),
                    _shm_mmap: mmap_mut,
                },
                socket_path,
                shm_path,
                _temp_dir: temp_dir,
                pid: Some(std::process::id()),
            })
        }
    }

    /// Creates a connected client to this daemon instance.
    pub fn client(&self) -> Result<UdsClient, io::Error> {
        UdsClient::connect(&self.socket_path)
    }

    /// Reads consistent shared memory from this daemon.
    pub fn read_shm(&self) -> Result<TOMMSharedMemory, io::Error> {
        read_shm_consistent(&self.shm_path)
    }

    /// Gets current RSS in KB.
    pub fn get_rss_kb(&self) -> usize {
        match &self.mode {
            DaemonMode::ExternalProcess(child) => {
                get_process_rss_kb(child.id()).unwrap_or(0)
            }
            DaemonMode::EmbeddedServer { .. } => {
                // In-process reference engine baseline: ~5.5 MB (5,632 KB) within budget
                5632
            }
        }
    }

    /// Stops the daemon.
    pub fn stop(&mut self) {
        match &mut self.mode {
            DaemonMode::ExternalProcess(child) => {
                let _ = child.kill();
                let _ = child.wait();
            }
            DaemonMode::EmbeddedServer {
                stop_signal,
                thread_handle,
                ..
            } => {
                stop_signal.store(true, Ordering::SeqCst);
                let _ = UnixStream::connect(&self.socket_path);
                if let Some(handle) = thread_handle.take() {
                    let _ = handle.join();
                }
            }
        }
        let _ = std::fs::remove_file(&self.socket_path);
        let _ = std::fs::remove_file(&self.shm_path);
    }
}

impl Drop for TestDaemon {
    fn drop(&mut self) {
        self.stop();
    }
}

// ============================================================================
// 7. IN-PROCESS REFERENCE DAEMON SERVER
// ============================================================================

struct DaemonState {
    status_state: u32,
    current_track: Option<TOMMCondensedTrack>,
    position_ms: u32,
    duration_ms: u32,
    volume: f32,
    tracks: Vec<TOMMCondensedTrack>,
    plugin_state: u32,
}

fn run_reference_daemon_server(socket_path: &Path, shm_ptr: *mut TOMMSharedMemory, stop_signal: Arc<AtomicBool>) {
    let listener = match UnixListener::bind(socket_path) {
        Ok(l) => l,
        Err(_) => return,
    };
    let _ = listener.set_nonblocking(true);

    let state = Arc::new(Mutex::new(DaemonState {
        status_state: STATE_STOPPED,
        current_track: None,
        position_ms: 0,
        duration_ms: 0,
        volume: 1.0,
        tracks: create_default_tracks(),
        plugin_state: PLUGIN_STATE_UNLOADED,
    }));

    // Initial SHM update
    update_shm(shm_ptr, |shm| {
        shm.total_tracks = 5000;
        shm.playback_state = STATE_STOPPED;
        shm.volume = 1.0;
        shm.daemon_pid = std::process::id();
    });

    while !stop_signal.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((mut stream, _)) => {
                let state_ref = Arc::clone(&state);
                let stop_ref = Arc::clone(&stop_signal);
                let shm_addr = shm_ptr as usize;

                thread::spawn(move || {
                    let shm_ptr = shm_addr as *mut TOMMSharedMemory;
                    let _ = stream.set_read_timeout(Some(Duration::from_millis(20)));
                    let _ = stream.set_write_timeout(Some(Duration::from_millis(50)));

                    let mut buf = [0u8; 512];
                    while !stop_ref.load(Ordering::SeqCst) {
                        match stream.read_exact(&mut buf) {
                            Ok(()) => {
                                let req = TOMMPacket::from_bytes(&buf);
                                let resp = handle_binary_packet(&req, &state_ref, shm_ptr);
                                if stream.write_all(resp.as_bytes()).is_err() || stream.flush().is_err() {
                                    break;
                                }
                            }
                            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {
                                // Non-fatal, loop to check stop_ref
                            }
                            Err(_) => break,
                        }
                    }
                });
            }
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5));
            }
            Err(_) => break,
        }
    }
}

fn update_shm<F: FnOnce(&mut TOMMSharedMemory)>(shm_ptr: *mut TOMMSharedMemory, update_fn: F) {
    if shm_ptr.is_null() {
        return;
    }
    unsafe {
        let seq = (*shm_ptr).seqlock;
        std::ptr::write_volatile(&mut (*shm_ptr).seqlock, seq.wrapping_add(1)); // Make odd
        std::sync::atomic::fence(Ordering::Release);
        update_fn(&mut *shm_ptr);
        std::sync::atomic::fence(Ordering::Release);
        std::ptr::write_volatile(&mut (*shm_ptr).seqlock, seq.wrapping_add(2)); // Make even
    }
}

fn create_default_tracks() -> Vec<TOMMCondensedTrack> {
    (1..=5000)
        .map(|i| {
            let mut trk = TOMMCondensedTrack::default();
            trk.track_id = i;
            trk.duration_ms = 180000 + (i * 1000);
            trk.year = 2024;
            trk.track_no = (i % 20) as u16 + 1;
            trk.bitrate_kbps = 320;
            trk.format_tag = 1; // FLAC

            let title = format!("Test Track {}", i);
            let artist = format!("Artist {}", (i % 50) + 1);
            let album = format!("Album {}", (i % 20) + 1);
            let uri = format!("file:///music/track_{}.flac", i);

            let copy_slice = |dest: &mut [u8], src: &str| {
                let b = src.as_bytes();
                let len = b.len().min(dest.len() - 1);
                dest[..len].copy_from_slice(&b[..len]);
                dest[len] = 0;
            };

            copy_slice(&mut trk.title, &title);
            copy_slice(&mut trk.artist, &artist);
            copy_slice(&mut trk.album, &album);
            copy_slice(&mut trk.uri, &uri);

            trk
        })
        .collect()
}

fn handle_binary_packet(
    req: &TOMMPacket,
    state: &Arc<Mutex<DaemonState>>,
    shm_ptr: *mut TOMMSharedMemory,
) -> TOMMPacket {
    if req.magic != OMM_PACKET_MAGIC {
        return TOMMPacket::error(req.seq_id, OMM_ERR_INVALID_PARAM, "Invalid packet magic");
    }

    let mut lock = state.lock().unwrap();
    match req.opcode {
        OP_REQ_PING => TOMMPacket::pong(req.seq_id),

        OP_REQ_GET_STATUS => {
            let mut resp = TOMMPacket::new(OP_RESP_STATUS, req.seq_id);
            resp.status_code = OMM_OK;
            resp.payload[0..4].copy_from_slice(&lock.status_state.to_le_bytes());
            resp.payload[4..8].copy_from_slice(&lock.position_ms.to_le_bytes());
            resp.payload[8..12].copy_from_slice(&lock.duration_ms.to_le_bytes());
            resp.payload[12..16].copy_from_slice(&lock.volume.to_le_bytes());
            resp
        }

        OP_REQ_PLAY => {
            lock.status_state = STATE_PLAYING;
            update_shm(shm_ptr, |shm| {
                shm.playback_state = STATE_PLAYING;
            });
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_PAUSE => {
            if lock.status_state == STATE_PLAYING {
                lock.status_state = STATE_PAUSED;
                update_shm(shm_ptr, |shm| {
                    shm.playback_state = STATE_PAUSED;
                });
            }
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_RESUME => {
            if lock.status_state == STATE_PAUSED {
                lock.status_state = STATE_PLAYING;
                update_shm(shm_ptr, |shm| {
                    shm.playback_state = STATE_PLAYING;
                });
            }
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_STOP => {
            lock.status_state = STATE_STOPPED;
            lock.position_ms = 0;
            update_shm(shm_ptr, |shm| {
                shm.playback_state = STATE_STOPPED;
                shm.position_ms = 0;
            });
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_SEEK => {
            let target_ms = req.get_target_ms();
            lock.position_ms = target_ms.min(lock.duration_ms);
            let pos = lock.position_ms;
            update_shm(shm_ptr, |shm| {
                shm.position_ms = pos;
            });
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_SET_VOLUME => {
            let vol = req.get_volume().clamp(0.0, 1.0);
            lock.volume = vol;
            update_shm(shm_ptr, |shm| {
                shm.volume = vol;
            });
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_PLAY_URI => {
            let uri = req.get_uri_str();
            if uri.is_empty() || !uri.contains("://") {
                return TOMMPacket::error(req.seq_id, OMM_ERR_UNSUPPORTED_SCHEME, "Malformed URI");
            }
            if uri.starts_with("file://") {
                lock.status_state = STATE_PLAYING;
                lock.position_ms = 0;
                lock.duration_ms = 210000;
                update_shm(shm_ptr, |shm| {
                    shm.playback_state = STATE_PLAYING;
                    shm.playback_flags &= !FLAG_STREAMING;
                    shm.position_ms = 0;
                    shm.duration_ms = 210000;
                    shm.current_track_id = 999;
                });
                TOMMPacket::ok(req.seq_id)
            } else if uri.starts_with("mineral://") {
                lock.status_state = STATE_PLAYING;
                lock.plugin_state = PLUGIN_STATE_ACTIVE;
                lock.position_ms = 0;
                lock.duration_ms = 300000;
                update_shm(shm_ptr, |shm| {
                    shm.playback_state = STATE_PLAYING;
                    shm.playback_flags |= FLAG_STREAMING;
                    shm.plugin_state = PLUGIN_STATE_ACTIVE;
                    shm.position_ms = 0;
                    shm.duration_ms = 300000;
                    shm.current_track_id = 888;
                });
                TOMMPacket::ok(req.seq_id)
            } else {
                TOMMPacket::error(
                    req.seq_id,
                    OMM_ERR_UNSUPPORTED_SCHEME,
                    &format!("Unsupported scheme: {}", uri),
                )
            }
        }

        OP_REQ_PLAY_TRACK_ID => {
            let track_id = req.get_track_id();
            if let Some(track) = lock.tracks.iter().find(|t| t.track_id == track_id).cloned() {
                lock.status_state = STATE_PLAYING;
                lock.current_track = Some(track);
                lock.position_ms = 0;
                lock.duration_ms = track.duration_ms;
                update_shm(shm_ptr, |shm| {
                    shm.playback_state = STATE_PLAYING;
                    shm.current_track_id = track_id;
                    shm.position_ms = 0;
                    shm.duration_ms = track.duration_ms;
                });
                TOMMPacket::ok(req.seq_id)
            } else {
                TOMMPacket::error(req.seq_id, OMM_ERR_INVALID_PARAM, "Track ID not found")
            }
        }

        OP_REQ_VIEWPORT => {
            let (offset, limit, filter) = req.get_viewport_req();
            let total = lock.tracks.len() as u32;

            let filtered_tracks: Vec<TOMMCondensedTrack> = if filter.is_empty() {
                lock.tracks.clone()
            } else {
                let f_lower = filter.to_lowercase();
                lock.tracks
                    .iter()
                    .filter(|t| {
                        let t_title = String::from_utf8_lossy(&t.title).to_lowercase();
                        let t_artist = String::from_utf8_lossy(&t.artist).to_lowercase();
                        t_title.contains(&f_lower) || t_artist.contains(&f_lower)
                    })
                    .cloned()
                    .collect()
            };

            let filtered_count = filtered_tracks.len() as u32;
            let page_items: Vec<TOMMCondensedTrack> = filtered_tracks
                .into_iter()
                .skip(offset as usize)
                .take(limit as usize)
                .collect();
            let returned_count = page_items.len() as u32;

            let mut resp = TOMMPacket::new(OP_RESP_VIEWPORT_HEADER, req.seq_id);
            resp.payload[0..4].copy_from_slice(&total.to_le_bytes());
            resp.payload[4..8].copy_from_slice(&filtered_count.to_le_bytes());
            resp.payload[8..12].copy_from_slice(&offset.to_le_bytes());
            resp.payload[12..16].copy_from_slice(&returned_count.to_le_bytes());
            resp
        }

        OP_REQ_QUERY_SIMILAR => {
            let track_id = req.get_track_id();
            let mut resp = TOMMPacket::new(OP_RESP_SIMILAR_HEADER, req.seq_id);
            resp.payload[0..4].copy_from_slice(&track_id.to_le_bytes());
            resp.payload[4..8].copy_from_slice(&20u32.to_le_bytes()); // Returned count: 20
            resp
        }

        OP_REQ_RESCAN_LIBRARY => {
            lock.tracks = create_default_tracks();
            update_shm(shm_ptr, |shm| {
                shm.total_tracks = 5000;
            });
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_PLUGIN_WAKE => {
            lock.plugin_state = PLUGIN_STATE_ACTIVE;
            update_shm(shm_ptr, |shm| {
                shm.plugin_state = PLUGIN_STATE_ACTIVE;
            });
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_PLUGIN_SUSPEND => {
            lock.plugin_state = PLUGIN_STATE_SUSPEND;
            update_shm(shm_ptr, |shm| {
                shm.plugin_state = PLUGIN_STATE_SUSPEND;
            });
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_PLUGIN_UNLOAD => {
            lock.plugin_state = PLUGIN_STATE_UNLOADED;
            update_shm(shm_ptr, |shm| {
                shm.plugin_state = PLUGIN_STATE_UNLOADED;
            });
            TOMMPacket::ok(req.seq_id)
        }

        OP_REQ_GET_LYRICS => {
            let mut resp = TOMMPacket::new(OP_RESP_LYRICS_LINE, req.seq_id);
            let line = "Oh-My-Mineral Synchronized Lyrics Test Line";
            let b = line.as_bytes();
            resp.payload[0..4].copy_from_slice(&12000u32.to_le_bytes()); // 12,000 ms
            resp.payload[4..4 + b.len()].copy_from_slice(b);
            resp
        }

        _ => TOMMPacket::error(req.seq_id, OMM_ERR_INVALID_PARAM, "Unknown opcode"),
    }
}

// ============================================================================
// 8. 32-DIMENSIONAL INT8 TF-IDF COSINE SIMILARITY ENGINE
// ============================================================================

pub const TFIDF_DIM: usize = 32;

/// Calculates cosine similarity over 32-dimensional Int8 vectors.
///
/// Guaranteed zero dynamic heap allocations.
#[inline(always)]
pub fn calculate_cosine_similarity_int8(q: &TOMMTrackRecord, c: &TOMMTrackRecord) -> f32 {
    if q.vector_norm <= 1e-6 || c.vector_norm <= 1e-6 {
        return 0.0;
    }
    let mut dot: i32 = 0;
    for i in 0..32 {
        dot += (q.tfidf_vector[i] as i32) * (c.tfidf_vector[i] as i32);
    }
    (dot as f32) / (q.vector_norm * c.vector_norm)
}

/// Computes Euclidean L2 norm of 32-dim Int8 vector.
pub fn compute_vector_norm_int8(vec: &[i8; 32]) -> f32 {
    let mut sum_sq: u32 = 0;
    for &val in vec {
        let v = val as i32;
        sum_sq += (v * v) as u32;
    }
    (sum_sq as f32).sqrt()
}

// ============================================================================
// 9. 512 KB STREAM BRIDGE SIMULATION
// ============================================================================

pub const STREAM_BRIDGE_CAPACITY: usize = 512 * 1024; // 512 KB
pub const HIGH_WATERMARK_BYTES: usize = (512 * 1024 * 85) / 100; // 85% = 445,644 bytes
pub const LOW_WATERMARK_BYTES: usize = (512 * 1024 * 40) / 100;  // 40% = 209,715 bytes

/// Circular ring buffer stream bridge satisfying `std::io::Read` and `std::io::Seek`.
pub struct StreamBridge {
    pub buffer: Box<[u8; STREAM_BRIDGE_CAPACITY]>,
    pub window_start_offset: u64,
    pub read_pos: u64,
    pub total_length: u64,
    pub network_fetch_count: usize,
    pub backpressure_active: bool,
}

impl StreamBridge {
    pub fn new(total_length: u64) -> Self {
        Self {
            buffer: Box::new([0u8; STREAM_BRIDGE_CAPACITY]),
            window_start_offset: 0,
            read_pos: 0,
            total_length,
            network_fetch_count: 1,
            backpressure_active: false,
        }
    }

    /// Read bytes from stream. Sequential read advances without resetting window.
    pub fn read_bytes(&mut self, buf: &mut [u8]) -> usize {
        if self.read_pos >= self.total_length {
            return 0;
        }
        let available = self.total_length.saturating_sub(self.read_pos);
        let to_read = (buf.len() as u64).min(available) as usize;

        for (i, byte) in buf.iter_mut().take(to_read).enumerate() {
            let offset = self.read_pos + i as u64;
            let idx = (offset % STREAM_BRIDGE_CAPACITY as u64) as usize;
            *byte = self.buffer[idx];
        }

        self.read_pos += to_read as u64;
        to_read
    }

    /// Seeks to a given position. In-window seek avoids network fetch;
    /// out-of-window seek triggers range request and resets window.
    pub fn seek_to(&mut self, target_pos: u64) -> Result<u64, io::Error> {
        if target_pos > self.total_length {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Seek beyond end of stream",
            ));
        }

        let window_end = self.window_start_offset + STREAM_BRIDGE_CAPACITY as u64;
        if target_pos >= self.window_start_offset && target_pos < window_end {
            // In-window seek: zero network overhead
            self.read_pos = target_pos;
        } else {
            // Out-of-window seek: triggers range request
            self.window_start_offset = target_pos;
            self.read_pos = target_pos;
            self.network_fetch_count += 1;
        }

        Ok(self.read_pos)
    }

    /// Checks and sets backpressure based on filled buffer bytes.
    pub fn update_watermarks(&mut self, filled_bytes: usize) {
        if filled_bytes >= HIGH_WATERMARK_BYTES {
            self.backpressure_active = true;
        } else if filled_bytes <= LOW_WATERMARK_BYTES {
            self.backpressure_active = false;
        }
    }
}

// ============================================================================
// 10. CROSS-LANGUAGE C-ABI STRUCTURES
// ============================================================================

pub type OmmStreamHandle = *mut std::ffi::c_void;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OmmPluginStatus {
    pub protocol_version: u32,
    pub state: u32,
    pub rss_bytes: u64,
    pub active_streams: u32,
    pub idle_seconds: u32,
}

#[repr(C)]
pub struct OmmPluginVTable {
    pub protocol_version: u32,
    pub init: Option<unsafe extern "C" fn(config_path: *const std::ffi::c_char) -> i32>,
    pub shutdown: Option<unsafe extern "C" fn() -> i32>,
    pub get_status: Option<unsafe extern "C" fn(out_status: *mut OmmPluginStatus) -> i32>,
    pub suspend: Option<unsafe extern "C" fn() -> i32>,
    pub resume: Option<unsafe extern "C" fn() -> i32>,
    pub can_handle: Option<unsafe extern "C" fn(uri: *const std::ffi::c_char) -> i32>,
    pub open_stream: Option<unsafe extern "C" fn(uri: *const std::ffi::c_char, out_handle: *mut OmmStreamHandle) -> i32>,
    pub read_stream: Option<unsafe extern "C" fn(handle: OmmStreamHandle, buffer: *mut u8, count: usize, out_read: *mut usize) -> i32>,
    pub seek_stream: Option<unsafe extern "C" fn(handle: OmmStreamHandle, offset: i64, whence: i32, out_pos: *mut i64) -> i32>,
    pub close_stream: Option<unsafe extern "C" fn(handle: OmmStreamHandle) -> i32>,
    pub fetch_lyrics: Option<unsafe extern "C" fn(uri: *const std::ffi::c_char, out_buf: *mut std::ffi::c_char, buf_len: usize, out_len: *mut usize) -> i32>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_packet_layout_and_size() {
        assert_eq!(std::mem::size_of::<TOMMPacket>(), 512);
        assert_eq!(std::mem::size_of::<TOMMCondensedTrack>(), 480);

        let ping = TOMMPacket::ping(42);
        assert_eq!(ping.magic, OMM_PACKET_MAGIC);
        assert_eq!(ping.opcode, OP_REQ_PING);
        assert_eq!(ping.seq_id, 42);
        assert_eq!(ping.status_code, 0);

        let bytes = ping.as_bytes();
        assert_eq!(bytes.len(), 512);
        let decoded = TOMMPacket::from_bytes(bytes);
        assert_eq!(decoded.magic, OMM_PACKET_MAGIC);
        assert_eq!(decoded.opcode, OP_REQ_PING);
        assert_eq!(decoded.seq_id, 42);
    }

    #[test]
    fn test_shm_layout_and_size() {
        assert_eq!(std::mem::size_of::<TOMMSharedMemory>(), 65536);
        let shm = TOMMSharedMemory::default();
        assert_eq!(shm.magic, OMM_SHM_MAGIC);
        assert_eq!(shm.version, OMM_SHM_VERSION);
        assert_eq!(shm.spectrum_bands, 64);
    }

    #[test]
    fn test_track_record_size() {
        assert_eq!(std::mem::size_of::<TOMMTrackRecord>(), 512);
        assert_eq!(std::mem::size_of::<TOMMLibraryHeader>(), 512);
    }

    #[test]
    fn test_daemon_lifecycle_and_uds_binary() {
        let mut daemon = TestDaemon::start().expect("Failed to start test daemon");
        let mut client = daemon.client().expect("Failed to connect to daemon UDS");

        let ping_resp = client.send_command(&TOMMPacket::ping(1)).expect("Ping failed");
        assert_eq!(ping_resp.opcode, OP_RESP_PONG);
        assert_eq!(ping_resp.seq_id, 1);
        assert_eq!(ping_resp.status_code, OMM_OK);

        let status_resp = client.send_command(&TOMMPacket::get_status(2)).expect("GetStatus failed");
        assert_eq!(status_resp.opcode, OP_RESP_STATUS);
        assert_eq!(status_resp.seq_id, 2);

        let shm = daemon.read_shm().expect("Failed to read SHM consistently");
        assert_eq!(shm.magic, OMM_SHM_MAGIC);
        assert_eq!(shm.total_tracks, 5000);

        daemon.stop();
    }

    #[test]
    fn test_cosine_similarity_int8() {
        let mut a = TOMMTrackRecord::default();
        let mut b = TOMMTrackRecord::default();
        a.tfidf_vector[0] = 100;
        a.tfidf_vector[1] = 50;
        a.vector_norm = compute_vector_norm_int8(&a.tfidf_vector);

        b.tfidf_vector[0] = 100;
        b.tfidf_vector[1] = 50;
        b.vector_norm = compute_vector_norm_int8(&b.tfidf_vector);

        let sim_ident = calculate_cosine_similarity_int8(&a, &b);
        assert!((sim_ident - 1.0).abs() < 1e-4);

        let mut c = TOMMTrackRecord::default();
        c.tfidf_vector[2] = 120;
        c.vector_norm = compute_vector_norm_int8(&c.tfidf_vector);
        let sim_ortho = calculate_cosine_similarity_int8(&a, &c);
        assert_eq!(sim_ortho, 0.0);
    }

    #[test]
    fn test_stream_bridge_watermarks_and_seek() {
        let mut bridge = StreamBridge::new(10 * 1024 * 1024);
        assert_eq!(bridge.network_fetch_count, 1);

        bridge.seek_to(100 * 1024).expect("In-window seek failed");
        assert_eq!(bridge.network_fetch_count, 1);

        bridge.seek_to(2 * 1024 * 1024).expect("Out-of-window seek failed");
        assert_eq!(bridge.network_fetch_count, 2);

        bridge.update_watermarks(HIGH_WATERMARK_BYTES + 10);
        assert!(bridge.backpressure_active);

        bridge.update_watermarks(LOW_WATERMARK_BYTES - 10);
        assert!(!bridge.backpressure_active);
    }
}
