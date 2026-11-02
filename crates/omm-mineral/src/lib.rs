//! Oh-My-Mineral Streaming Plugin (`libomm_mineral.so`)
//! C-ABI VTable Export, Zero-Panic Boundary Shields & Lifecycle Watchdog

pub mod config;
pub mod lyrics;
pub mod online;
pub mod ring_buffer;
pub mod streaming;

use std::ffi::{c_char, c_void, CStr};
use std::slice;
use std::sync::atomic::Ordering;

pub use lyrics::{copy_lyrics_to_caller_buffer, get_lyrics_for_uri};
pub use online::OmmCondensedTrack;
pub use ring_buffer::SpscRingBuffer;
pub use streaming::{
    OmmPluginStatus, PluginEngine, GLOBAL_ENGINE, OMM_ERR_AUTH_REQUIRED,
    OMM_ERR_BUFFER_TOO_SMALL, OMM_ERR_DECODE_FAILURE, OMM_ERR_GENERIC,
    OMM_ERR_INVALID_PARAM, OMM_ERR_NETWORK_FAILURE, OMM_ERR_PANIC,
    OMM_ERR_STREAM_EOF, OMM_ERR_STREAM_TIMEOUT, OMM_ERR_SUSPENDED,
    OMM_ERR_UNSUPPORTED_URI, OMM_OK, OMM_PLUGIN_ACTIVE, OMM_PLUGIN_DEEP_UNLOAD,
    OMM_PLUGIN_LAZY_WAKEUP, OMM_PLUGIN_PROTOCOL_VERSION, OMM_PLUGIN_SUSPENDED,
    OMM_PLUGIN_UNLOADED,
};

pub type OmmStreamHandle = *mut c_void;

#[repr(C)]
pub struct OmmPluginVTable {
    pub protocol_version: u32,
    pub init: Option<unsafe extern "C" fn(config_path: *const c_char) -> i32>,
    pub shutdown: Option<unsafe extern "C" fn() -> i32>,
    pub get_status: Option<unsafe extern "C" fn(out_status: *mut OmmPluginStatus) -> i32>,
    pub suspend: Option<unsafe extern "C" fn() -> i32>,
    pub resume: Option<unsafe extern "C" fn() -> i32>,
    pub can_handle: Option<unsafe extern "C" fn(uri: *const c_char) -> i32>,
    pub open_stream: Option<unsafe extern "C" fn(uri: *const c_char, out_handle: *mut OmmStreamHandle) -> i32>,
    pub read_stream: Option<unsafe extern "C" fn(handle: OmmStreamHandle, buffer: *mut u8, count: usize, out_read: *mut usize) -> i32>,
    pub seek_stream: Option<unsafe extern "C" fn(handle: OmmStreamHandle, offset: i64, whence: i32, out_pos: *mut i64) -> i32>,
    pub close_stream: Option<unsafe extern "C" fn(handle: OmmStreamHandle) -> i32>,
    pub fetch_lyrics: Option<unsafe extern "C" fn(uri: *const c_char, out_buf: *mut c_char, buf_len: usize, out_len: *mut usize) -> i32>,
}

// Compile-time static assertions ensuring byte-for-byte C-ABI compatibility
const _: () = {
    assert!(std::mem::size_of::<OmmPluginStatus>() == 24);
    assert!(std::mem::align_of::<OmmPluginStatus>() == 8);
    assert!(std::mem::size_of::<OmmPluginVTable>() == 96);
    assert!(std::mem::align_of::<OmmPluginVTable>() == 8);
    assert!(std::mem::size_of::<OmmStreamHandle>() == 8);
};

// ----------------------------------------------------------------------------
// Zero-Panic FFI Boundary Shield
// ----------------------------------------------------------------------------

#[inline]
pub fn ffi_guard<F>(f: F) -> i32
where
    F: FnOnce() -> i32,
{
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(code) => code,
        Err(_) => {
            eprintln!("[omm_mineral] Intercepted panic at C-ABI boundary -> returning OMM_ERR_PANIC (-999)");
            OMM_ERR_PANIC
        }
    }
}

// ----------------------------------------------------------------------------
// Exported C-ABI Function Implementations
// ----------------------------------------------------------------------------

pub unsafe extern "C" fn plugin_init(config_path: *const c_char) -> i32 {
    ffi_guard(|| {
        let path_opt = if config_path.is_null() {
            None
        } else {
            match CStr::from_ptr(config_path).to_str() {
                Ok(s) => Some(s),
                Err(_) => return OMM_ERR_INVALID_PARAM,
            }
        };

        let mut lock = GLOBAL_ENGINE.write();
        let engine = lock.get_or_insert_with(PluginEngine::new);
        engine.init(path_opt)
    })
}

pub unsafe extern "C" fn plugin_shutdown() -> i32 {
    ffi_guard(|| {
        let mut lock = GLOBAL_ENGINE.write();
        if let Some(mut engine) = lock.take() {
            engine.shutdown();
        }
        OMM_OK
    })
}

pub unsafe extern "C" fn plugin_get_status(out_status: *mut OmmPluginStatus) -> i32 {
    ffi_guard(|| {
        if out_status.is_null() {
            return OMM_ERR_INVALID_PARAM;
        }
        let lock = GLOBAL_ENGINE.read();
        if let Some(engine) = lock.as_ref() {
            *out_status = engine.get_status();
        } else {
            *out_status = OmmPluginStatus {
                protocol_version: OMM_PLUGIN_PROTOCOL_VERSION,
                state: OMM_PLUGIN_UNLOADED,
                rss_bytes: 0,
                active_streams: 0,
                idle_seconds: 0,
            };
        }
        OMM_OK
    })
}

pub unsafe extern "C" fn plugin_suspend() -> i32 {
    ffi_guard(|| {
        let mut lock = GLOBAL_ENGINE.write();
        if let Some(engine) = lock.as_mut() {
            engine.suspend()
        } else {
            OMM_OK
        }
    })
}

pub unsafe extern "C" fn plugin_resume() -> i32 {
    ffi_guard(|| {
        let mut lock = GLOBAL_ENGINE.write();
        if let Some(engine) = lock.as_mut() {
            engine.resume()
        } else {
            OMM_OK
        }
    })
}

pub unsafe extern "C" fn plugin_can_handle(uri: *const c_char) -> i32 {
    ffi_guard(|| {
        if uri.is_null() {
            return 0;
        }
        let uri_str = match CStr::from_ptr(uri).to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        };
        PluginEngine::can_handle(uri_str)
    })
}

const HANDLE_OFFSET: usize = 0x10000;

#[inline]
pub fn id_to_handle(id: u32) -> OmmStreamHandle {
    (HANDLE_OFFSET + id as usize) as OmmStreamHandle
}

#[inline]
pub fn handle_to_id(handle: OmmStreamHandle) -> Option<u32> {
    let val = handle as usize;
    if val == 0 {
        return None;
    }
    if val >= HANDLE_OFFSET {
        Some((val - HANDLE_OFFSET) as u32)
    } else {
        // Fallback for legacy 1-based handle values
        Some(val as u32)
    }
}

pub unsafe extern "C" fn plugin_open_stream(
    uri: *const c_char,
    out_handle: *mut OmmStreamHandle,
) -> i32 {
    ffi_guard(|| {
        if uri.is_null() || out_handle.is_null() {
            return OMM_ERR_INVALID_PARAM;
        }
        let uri_str = match CStr::from_ptr(uri).to_str() {
            Ok(s) => s,
            Err(_) => return OMM_ERR_INVALID_PARAM,
        };

        // Resolve online audio file OUTSIDE GLOBAL_ENGINE.write() so network I/O never blocks other operations
        let cached_audio_path = crate::online::resolve_online_audio_file(uri_str);

        let mut lock = GLOBAL_ENGINE.write();
        let engine = lock.get_or_insert_with(PluginEngine::new);

        match engine.open_stream_with_cached(uri_str, cached_audio_path) {
            Ok(handle_id) => {
                *out_handle = id_to_handle(handle_id);
                OMM_OK
            }
            Err(err) => {
                *out_handle = std::ptr::null_mut();
                err
            }
        }
    })
}

pub unsafe extern "C" fn plugin_read_stream(
    handle: OmmStreamHandle,
    buffer: *mut u8,
    count: usize,
    out_read: *mut usize,
) -> i32 {
    ffi_guard(|| {
        if handle.is_null() || buffer.is_null() || out_read.is_null() {
            return OMM_ERR_INVALID_PARAM;
        }
        *out_read = 0;

        let handle_id = match handle_to_id(handle) {
            Some(id) => id,
            None => return OMM_ERR_INVALID_PARAM,
        };

        // 1. Fetch Arc<StreamSession> under transient read lock (< 50 ns)
        let session = {
            let lock = GLOBAL_ENGINE.read();
            let engine = match lock.as_ref() {
                Some(e) => e,
                None => return OMM_ERR_GENERIC,
            };
            if engine.lifecycle_state.load(Ordering::Acquire) == OMM_PLUGIN_SUSPENDED {
                return OMM_ERR_SUSPENDED;
            }
            match engine.get_stream(handle_id) {
                Ok(s) => {
                    engine.record_activity();
                    s
                }
                Err(err) => return err,
            }
        }; // GLOBAL_ENGINE and streams locks are DROPPED HERE!

        // 2. Perform stream I/O directly on Arc<StreamSession>
        // ZERO locks held on GLOBAL_ENGINE during the 200ms timeout!
        let slice = slice::from_raw_parts_mut(buffer, count);
        let res = session.read_bytes(slice);

        // Check if engine was suspended during the read
        {
            let lock = GLOBAL_ENGINE.read();
            if let Some(engine) = lock.as_ref() {
                if engine.lifecycle_state.load(Ordering::Acquire) == OMM_PLUGIN_SUSPENDED {
                    return OMM_ERR_SUSPENDED;
                }
            }
        }

        match res {
            Ok(bytes_read) => {
                *out_read = bytes_read;
                OMM_OK
            }
            Err(err) => err,
        }
    })
}

pub unsafe extern "C" fn plugin_seek_stream(
    handle: OmmStreamHandle,
    offset: i64,
    whence: i32,
    out_pos: *mut i64,
) -> i32 {
    ffi_guard(|| {
        if handle.is_null() || out_pos.is_null() {
            return OMM_ERR_INVALID_PARAM;
        }

        let handle_id = match handle_to_id(handle) {
            Some(id) => id,
            None => return OMM_ERR_INVALID_PARAM,
        };

        // 1. Fetch Arc<StreamSession> under transient read lock (< 50 ns)
        let session = {
            let lock = GLOBAL_ENGINE.read();
            let engine = match lock.as_ref() {
                Some(e) => e,
                None => return OMM_ERR_GENERIC,
            };
            if engine.lifecycle_state.load(Ordering::Acquire) == OMM_PLUGIN_SUSPENDED {
                return OMM_ERR_SUSPENDED;
            }
            match engine.get_stream(handle_id) {
                Ok(s) => {
                    engine.record_activity();
                    s
                }
                Err(err) => return err,
            }
        }; // Lock dropped immediately

        // 2. Perform seek directly on Arc<StreamSession>
        let res = session.seek(offset, whence, &mut *out_pos);

        // Check if engine was suspended during the seek
        {
            let lock = GLOBAL_ENGINE.read();
            if let Some(engine) = lock.as_ref() {
                if engine.lifecycle_state.load(Ordering::Acquire) == OMM_PLUGIN_SUSPENDED {
                    return OMM_ERR_SUSPENDED;
                }
            }
        }

        match res {
            Ok(_) => OMM_OK,
            Err(err) => err,
        }
    })
}

pub unsafe extern "C" fn plugin_close_stream(handle: OmmStreamHandle) -> i32 {
    ffi_guard(|| {
        if handle.is_null() {
            return OMM_ERR_INVALID_PARAM;
        }

        let handle_id = match handle_to_id(handle) {
            Some(id) => id,
            None => return OMM_ERR_INVALID_PARAM,
        };

        // 1. Remove session under transient read lock on engine (< 50 ns)
        let session = {
            let lock = GLOBAL_ENGINE.read();
            let engine = match lock.as_ref() {
                Some(e) => e,
                None => return OMM_ERR_GENERIC,
            };
            engine.record_activity();
            match engine.remove_stream(handle_id) {
                Some(s) => s,
                None => return OMM_ERR_INVALID_PARAM,
            }
        }; // Lock dropped immediately

        // 2. Close session directly (signals EOF, wakes condvars, unblocks readers/writers)
        session.close();
        OMM_OK
    })
}

pub unsafe extern "C" fn plugin_fetch_lyrics(
    uri: *const c_char,
    out_buf: *mut c_char,
    buf_len: usize,
    out_len: *mut usize,
) -> i32 {
    ffi_guard(|| {
        copy_lyrics_to_caller_buffer(uri, out_buf, buf_len, out_len)
    })
}

// ----------------------------------------------------------------------------
// Static VTable Singleton & Dynamic Entry Point
// ----------------------------------------------------------------------------

static PLUGIN_VTABLE: OmmPluginVTable = OmmPluginVTable {
    protocol_version: OMM_PLUGIN_PROTOCOL_VERSION,
    init: Some(plugin_init),
    shutdown: Some(plugin_shutdown),
    get_status: Some(plugin_get_status),
    suspend: Some(plugin_suspend),
    resume: Some(plugin_resume),
    can_handle: Some(plugin_can_handle),
    open_stream: Some(plugin_open_stream),
    read_stream: Some(plugin_read_stream),
    seek_stream: Some(plugin_seek_stream),
    close_stream: Some(plugin_close_stream),
    fetch_lyrics: Some(plugin_fetch_lyrics),
};

#[no_mangle]
pub extern "C" fn omm_plugin_get_vtable(protocol_version: u32) -> *const OmmPluginVTable {
    std::panic::catch_unwind(|| {
        if protocol_version == OMM_PLUGIN_PROTOCOL_VERSION {
            &PLUGIN_VTABLE as *const OmmPluginVTable
        } else {
            std::ptr::null()
        }
    })
    .unwrap_or(std::ptr::null())
}

#[no_mangle]
pub unsafe extern "C" fn omm_plugin_search(
    query: *const c_char,
    out_tracks: *mut OmmCondensedTrack,
    max_tracks: usize,
    out_count: *mut usize,
) -> i32 {
    ffi_guard(|| {
        if query.is_null() || out_tracks.is_null() || out_count.is_null() {
            return OMM_ERR_INVALID_PARAM;
        }
        *out_count = 0;

        let query_str = match CStr::from_ptr(query).to_str() {
            Ok(s) => s,
            Err(_) => return OMM_ERR_INVALID_PARAM,
        };

        {
            let mut lock = GLOBAL_ENGINE.write();
            let engine = lock.get_or_insert_with(PluginEngine::new);
            let _ = engine.ensure_runtime();
            engine.record_activity();
        }

        match online::search_online_tracks(query_str, max_tracks) {
            Ok(tracks) => {
                let count = tracks.len().min(max_tracks);
                if count > 0 {
                    let dst = slice::from_raw_parts_mut(out_tracks, count);
                    dst.copy_from_slice(&tracks[..count]);
                }
                *out_count = count;
                OMM_OK
            }
            Err(code) => code,
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn omm_plugin_get_track_meta(
    uri: *const c_char,
    out_track: *mut OmmCondensedTrack,
) -> i32 {
    ffi_guard(|| {
        if uri.is_null() || out_track.is_null() {
            return OMM_ERR_INVALID_PARAM;
        }
        let uri_str = match CStr::from_ptr(uri).to_str() {
            Ok(s) => s,
            Err(_) => return OMM_ERR_INVALID_PARAM,
        };
        if let Some(meta) = online::get_cached_track_meta(uri_str) {
            *out_track = meta;
            OMM_OK
        } else {
            OMM_ERR_GENERIC
        }
    })
}
