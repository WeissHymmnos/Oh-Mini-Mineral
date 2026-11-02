//! 512KB Bounded SPSC Lock-Free Ring Buffer with Backpressure & Underrun Guard
//!
//! Complies with Oh-My-Mineral RFC blueprint:
//! - Capacity: 524,288 bytes (512 KB, 2^19)
//! - Mask: 0x0007_FFFF
//! - High Watermark: 445,644 bytes (85%)
//! - Low Watermark: 209,715 bytes (40%)
//! - Read Timeout: 200ms -> OMM_ERR_STREAM_TIMEOUT (-7)
//! - Cache-aligned SPSC atomic cursors (zero heap allocations during steady-state)

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub const RING_BUFFER_CAPACITY: usize = 512 * 1024; // 524,288 bytes
pub const RING_BUFFER_MASK: usize = RING_BUFFER_CAPACITY - 1; // 0x0007_FFFF
pub const HIGH_WATERMARK_BYTES: usize = (RING_BUFFER_CAPACITY * 85) / 100; // 445,644 bytes (85%)
pub const LOW_WATERMARK_BYTES: usize = (RING_BUFFER_CAPACITY * 40) / 100;  // 209,715 bytes (40%)
pub const READ_TIMEOUT_MS: u64 = 200;

// Standard Error Codes matching omm_abi.h
pub const OMM_OK: i32 = 0;
pub const OMM_ERR_INVALID_PARAM: i32 = -2;
pub const OMM_ERR_STREAM_EOF: i32 = -6;
pub const OMM_ERR_STREAM_TIMEOUT: i32 = -7;

#[repr(align(64))]
pub struct CachePadded<T>(pub T);

pub struct SpscRingBuffer {
    buffer: Box<UnsafeCell<[u8; RING_BUFFER_CAPACITY]>>,

    // Cache-line isolated atomic cursors
    write_cursor: CachePadded<AtomicU64>,
    read_cursor: CachePadded<AtomicU64>,

    // Backpressure synchronization
    backpressure_active: AtomicBool,
    backpressure_notify: Arc<tokio::sync::Notify>,

    // Write / Seek mutual exclusion (eliminates TOCTOU cursor overwrite race)
    write_mutex: parking_lot::Mutex<()>,

    // 200ms empty-buffer timeout synchronization
    empty_mutex: Mutex<()>,
    empty_condvar: Condvar,

    // Stream status & seek control
    is_closed: AtomicBool,
    is_eof: AtomicBool,
    epoch: AtomicU64,
    logical_start_offset: AtomicU64,
    total_length: AtomicU64,
    network_fetch_count: AtomicUsize,
}

// UnsafeCell makes SpscRingBuffer !Sync by default.
// SpscRingBuffer enforces SPSC access on non-overlapping byte ranges via acquire-release cursors,
// and protects flush operations via write_mutex.
unsafe impl Send for SpscRingBuffer {}
unsafe impl Sync for SpscRingBuffer {}

impl SpscRingBuffer {
    pub fn new(total_length: u64) -> Self {
        Self {
            buffer: Box::new(UnsafeCell::new([0u8; RING_BUFFER_CAPACITY])),
            write_cursor: CachePadded(AtomicU64::new(0)),
            read_cursor: CachePadded(AtomicU64::new(0)),
            backpressure_active: AtomicBool::new(false),
            backpressure_notify: Arc::new(tokio::sync::Notify::new()),
            write_mutex: parking_lot::Mutex::new(()),
            empty_mutex: Mutex::new(()),
            empty_condvar: Condvar::new(),
            is_closed: AtomicBool::new(false),
            is_eof: AtomicBool::new(false),
            epoch: AtomicU64::new(0),
            logical_start_offset: AtomicU64::new(0),
            total_length: AtomicU64::new(total_length),
            network_fetch_count: AtomicUsize::new(1),
        }
    }

    pub fn get_backpressure_notify(&self) -> Arc<tokio::sync::Notify> {
        self.backpressure_notify.clone()
    }

    pub fn current_epoch(&self) -> u64 {
        self.epoch.load(Ordering::Acquire)
    }

    pub fn is_backpressure_active(&self) -> bool {
        self.backpressure_active.load(Ordering::Acquire)
    }

    pub fn get_network_fetch_count(&self) -> usize {
        self.network_fetch_count.load(Ordering::Acquire)
    }

    pub fn get_total_length(&self) -> u64 {
        self.total_length.load(Ordering::Acquire)
    }

    pub fn set_total_length(&self, len: u64) {
        self.total_length.store(len, Ordering::Release);
    }

    pub fn current_position(&self) -> u64 {
        self.logical_start_offset.load(Ordering::Acquire) + self.read_cursor.0.load(Ordering::Relaxed)
    }

    pub fn occupied_bytes(&self) -> usize {
        let write = self.write_cursor.0.load(Ordering::Acquire);
        let read = self.read_cursor.0.load(Ordering::Relaxed);
        (write.saturating_sub(read)) as usize
    }

    pub fn fill_ratio(&self) -> f32 {
        let occ = self.occupied_bytes();
        occ as f32 / RING_BUFFER_CAPACITY as f32
    }

    #[inline]
    pub fn is_closed(&self) -> bool {
        self.is_closed.load(Ordering::Acquire)
    }

    pub fn close(&self) {
        self.is_closed.store(true, Ordering::Release);
        self.is_eof.store(true, Ordering::Release);
        self.backpressure_active.store(false, Ordering::Release);
        self.epoch.fetch_add(1, Ordering::SeqCst);

        // Wake all Tokio async waiters (producer tasks blocked on backpressure or buffer full)
        self.backpressure_notify.notify_waiters();

        // Wake all sync threads (audio thread blocked on empty_condvar in read_bytes)
        let _lock = self.empty_mutex.lock().unwrap();
        self.empty_condvar.notify_all();
    }

    pub fn set_eof(&self) {
        self.is_eof.store(true, Ordering::Release);
        let _lock = self.empty_mutex.lock().unwrap();
        self.empty_condvar.notify_all();
    }

    pub fn is_eof(&self) -> bool {
        self.is_eof.load(Ordering::Acquire)
    }

    /// Producer: Push slice into ring buffer. Handles backpressure & wrap-around.
    pub async fn write_chunk(&self, chunk: &[u8], epoch: u64) -> Result<usize, i32> {
        if self.is_closed.load(Ordering::Acquire) {
            return Err(OMM_ERR_STREAM_EOF);
        }
        if self.epoch.load(Ordering::Acquire) != epoch {
            return Err(-1); // Stale epoch from seek
        }

        let mut written = 0;
        while written < chunk.len() {
            if self.is_closed.load(Ordering::Acquire) {
                return Err(OMM_ERR_STREAM_EOF);
            }
            if self.epoch.load(Ordering::Acquire) != epoch {
                return Err(-1);
            }

            let write = self.write_cursor.0.load(Ordering::Relaxed);
            let read = self.read_cursor.0.load(Ordering::Acquire);
            let filled = (write - read) as usize;
            let free = RING_BUFFER_CAPACITY.saturating_sub(filled);

            // Watermark Check: >= 85% full activates backpressure
            if filled >= HIGH_WATERMARK_BYTES {
                self.backpressure_active.store(true, Ordering::Release);
                while self.backpressure_active.load(Ordering::Acquire) {
                    if self.is_closed.load(Ordering::Acquire) {
                        return Err(OMM_ERR_STREAM_EOF);
                    }
                    self.backpressure_notify.notified().await;
                    if self.is_closed.load(Ordering::Acquire) {
                        return Err(OMM_ERR_STREAM_EOF);
                    }
                    if self.epoch.load(Ordering::Acquire) != epoch {
                        return Err(-1);
                    }
                }
                continue;
            }

            if free == 0 {
                // Buffer full, wait for consumer
                if self.is_closed.load(Ordering::Acquire) {
                    return Err(OMM_ERR_STREAM_EOF);
                }
                self.backpressure_notify.notified().await;
                if self.is_closed.load(Ordering::Acquire) {
                    return Err(OMM_ERR_STREAM_EOF);
                }
                if self.epoch.load(Ordering::Acquire) != epoch {
                    return Err(-1);
                }
                continue;
            }

            let to_write = (chunk.len() - written).min(free);
            let start_idx = (write as usize) & RING_BUFFER_MASK;
            let first_part = (RING_BUFFER_CAPACITY - start_idx).min(to_write);

            // Synchronize buffer write and write_cursor store with out-of-window seek flush
            {
                let _guard = self.write_mutex.lock();
                if self.is_closed.load(Ordering::Acquire) {
                    return Err(OMM_ERR_STREAM_EOF);
                }
                if self.epoch.load(Ordering::Acquire) != epoch {
                    return Err(-1);
                }

                unsafe {
                    let base = self.buffer.get() as *mut u8;
                    std::ptr::copy_nonoverlapping(chunk.as_ptr().add(written), base.add(start_idx), first_part);
                    let second_part = to_write - first_part;
                    if second_part > 0 {
                        std::ptr::copy_nonoverlapping(chunk.as_ptr().add(written + first_part), base, second_part);
                    }
                }

                let new_write = write + to_write as u64;
                self.write_cursor.0.store(new_write, Ordering::Release);

                // Immediate backpressure check on updated filled level
                let new_filled = (new_write - read) as usize;
                if new_filled >= HIGH_WATERMARK_BYTES {
                    self.backpressure_active.store(true, Ordering::Release);
                }
            }

            written += to_write;

            // Notify consumer if buffer was empty
            if filled == 0 {
                let _lock = self.empty_mutex.lock().unwrap();
                self.empty_condvar.notify_one();
            }
        }

        Ok(written)
    }

    /// Synchronous write (e.g. for synthetic fixtures or preloading)
    pub fn write_chunk_sync(&self, chunk: &[u8], epoch: u64) -> Result<usize, i32> {
        if self.is_closed.load(Ordering::Acquire) {
            return Err(OMM_ERR_STREAM_EOF);
        }
        if self.epoch.load(Ordering::Acquire) != epoch {
            return Err(-1);
        }

        let _guard = self.write_mutex.lock();
        if self.is_closed.load(Ordering::Acquire) {
            return Err(OMM_ERR_STREAM_EOF);
        }
        if self.epoch.load(Ordering::Acquire) != epoch {
            return Err(-1);
        }

        let write = self.write_cursor.0.load(Ordering::Relaxed);
        let read = self.read_cursor.0.load(Ordering::Acquire);
        let filled = (write - read) as usize;
        let free = RING_BUFFER_CAPACITY.saturating_sub(filled);

        if free == 0 {
            return Ok(0);
        }

        let to_write = chunk.len().min(free);
        let start_idx = (write as usize) & RING_BUFFER_MASK;
        let first_part = (RING_BUFFER_CAPACITY - start_idx).min(to_write);

        unsafe {
            let base = self.buffer.get() as *mut u8;
            std::ptr::copy_nonoverlapping(chunk.as_ptr(), base.add(start_idx), first_part);
            let second_part = to_write - first_part;
            if second_part > 0 {
                std::ptr::copy_nonoverlapping(chunk.as_ptr().add(first_part), base, second_part);
            }
        }

        let new_filled = filled + to_write;
        if new_filled >= HIGH_WATERMARK_BYTES {
            self.backpressure_active.store(true, Ordering::Release);
        }

        let new_write = write + to_write as u64;
        self.write_cursor.0.store(new_write, Ordering::Release);

        if filled == 0 {
            let _lock = self.empty_mutex.lock().unwrap();
            self.empty_condvar.notify_one();
        }

        Ok(to_write)
    }

    /// Consumer: Pull bytes into caller-allocated buffer. Enforces 200ms timeout on empty.
    pub fn read_bytes(&self, out_buf: &mut [u8]) -> Result<usize, i32> {
        if out_buf.is_empty() {
            return Ok(0);
        }

        let mut write = self.write_cursor.0.load(Ordering::Acquire);
        let mut read = self.read_cursor.0.load(Ordering::Relaxed);
        let mut available = (write.saturating_sub(read)) as usize;

        if available == 0 {
            if self.is_closed.load(Ordering::Acquire) || self.is_eof.load(Ordering::Acquire) {
                return Ok(0); // Clean EOF
            }

            let start = Instant::now();
            let timeout = Duration::from_millis(READ_TIMEOUT_MS);
            let mut guard = self.empty_mutex.lock().unwrap();

            while self.write_cursor.0.load(Ordering::Acquire) == self.read_cursor.0.load(Ordering::Relaxed) {
                if self.is_closed.load(Ordering::Acquire) || self.is_eof.load(Ordering::Acquire) {
                    return Ok(0);
                }
                let elapsed = start.elapsed();
                if elapsed >= timeout {
                    return Err(OMM_ERR_STREAM_TIMEOUT); // 200ms timeout underrun
                }
                let remaining = timeout - elapsed;
                let (new_guard, res) = self.empty_condvar.wait_timeout(guard, remaining).unwrap();
                guard = new_guard;
                if self.is_closed.load(Ordering::Acquire) || self.is_eof.load(Ordering::Acquire) {
                    return Ok(0);
                }
                if res.timed_out() && self.write_cursor.0.load(Ordering::Acquire) == self.read_cursor.0.load(Ordering::Relaxed) {
                    return Err(OMM_ERR_STREAM_TIMEOUT);
                }
            }
            drop(guard);

            write = self.write_cursor.0.load(Ordering::Acquire);
            read = self.read_cursor.0.load(Ordering::Relaxed);
            available = (write.saturating_sub(read)) as usize;
        }

        let to_read = out_buf.len().min(available);
        let start_idx = (read as usize) & RING_BUFFER_MASK;
        let first_part = (RING_BUFFER_CAPACITY - start_idx).min(to_read);

        unsafe {
            let base = self.buffer.get() as *const u8;
            std::ptr::copy_nonoverlapping(base.add(start_idx), out_buf.as_mut_ptr(), first_part);
            let second_part = to_read - first_part;
            if second_part > 0 {
                std::ptr::copy_nonoverlapping(base, out_buf.as_mut_ptr().add(first_part), second_part);
            }
        }

        let new_read = read + to_read as u64;
        self.read_cursor.0.store(new_read, Ordering::Release);

        // Low Watermark Check: <= 40% full releases backpressure
        let remaining_filled = (write.saturating_sub(new_read)) as usize;
        if self.backpressure_active.load(Ordering::Acquire) && remaining_filled <= LOW_WATERMARK_BYTES {
            self.backpressure_active.store(false, Ordering::Release);
            self.backpressure_notify.notify_one();
        }

        Ok(to_read)
    }

    /// Seek: Handles in-window hits (zero network I/O) vs out-of-window range requests.
    pub fn seek(&self, offset: i64, whence: i32, out_pos: &mut i64) -> Result<i64, i32> {
        if self.is_closed.load(Ordering::Acquire) {
            return Err(OMM_ERR_STREAM_EOF);
        }

        let total = self.total_length.load(Ordering::Acquire);
        let current_logical = self.logical_start_offset.load(Ordering::Acquire) + self.read_cursor.0.load(Ordering::Relaxed);

        let target: i64 = match whence {
            0 => offset,                          // SEEK_SET
            1 => current_logical as i64 + offset, // SEEK_CUR
            2 => total as i64 + offset,           // SEEK_END
            _ => return Err(OMM_ERR_INVALID_PARAM),
        };

        if target < 0 || (total > 0 && target as u64 > total) {
            return Err(OMM_ERR_INVALID_PARAM);
        }
        let target_pos = target as u64;

        let window_base = self.logical_start_offset.load(Ordering::Acquire);
        let write = self.write_cursor.0.load(Ordering::Acquire);

        // The buffer retains data written within the last RING_BUFFER_CAPACITY bytes:
        let buffered_start = window_base + write.saturating_sub(RING_BUFFER_CAPACITY as u64);
        let buffered_end = window_base + write;

        // In-Window Hit: target is within the valid buffered byte range
        if target_pos >= buffered_start && target_pos <= buffered_end {
            let offset_in_buf = target_pos - window_base;
            self.read_cursor.0.store(offset_in_buf, Ordering::Release);

            // Synchronize backpressure and underrun state with new read cursor
            let new_filled = (write.saturating_sub(offset_in_buf)) as usize;
            if new_filled >= HIGH_WATERMARK_BYTES {
                self.backpressure_active.store(true, Ordering::Release);
            } else if self.backpressure_active.load(Ordering::Acquire) && new_filled <= LOW_WATERMARK_BYTES {
                self.backpressure_active.store(false, Ordering::Release);
                self.backpressure_notify.notify_one();
            }

            if new_filled > 0 {
                let _lock = self.empty_mutex.lock().unwrap();
                self.empty_condvar.notify_one();
            }

            *out_pos = target_pos as i64;
            return Ok(target_pos as i64);
        }

        // Out-of-Window: Invalidate epoch, flush buffer under write_mutex, increment fetch count
        {
            let _guard = self.write_mutex.lock();
            self.epoch.fetch_add(1, Ordering::SeqCst);
            self.write_cursor.0.store(0, Ordering::Release);
            self.read_cursor.0.store(0, Ordering::Release);
            self.logical_start_offset.store(target_pos, Ordering::Release);
            self.is_eof.store(false, Ordering::Release);
            self.backpressure_active.store(false, Ordering::Release);
            self.network_fetch_count.fetch_add(1, Ordering::SeqCst);
        }

        // Wake up any blocked producers to initiate range download
        self.backpressure_notify.notify_waiters();

        // Wake up any blocked readers
        let _lock = self.empty_mutex.lock().unwrap();
        self.empty_condvar.notify_all();

        *out_pos = target_pos as i64;
        Ok(target_pos as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_capacity_and_geometry() {
        assert_eq!(RING_BUFFER_CAPACITY, 524288);
        assert_eq!(HIGH_WATERMARK_BYTES, 445644);
        assert_eq!(LOW_WATERMARK_BYTES, 209715);
    }

    #[test]
    fn test_sequential_read_write() {
        let rb = SpscRingBuffer::new(1024 * 1024);
        let epoch = rb.current_epoch();

        let data = vec![0xABu8; 4096];
        let written = rb.write_chunk_sync(&data, epoch).unwrap();
        assert_eq!(written, 4096);
        assert_eq!(rb.occupied_bytes(), 4096);

        let mut out = [0u8; 2048];
        let r1 = rb.read_bytes(&mut out).unwrap();
        assert_eq!(r1, 2048);
        assert_eq!(out[0], 0xAB);
        assert_eq!(rb.occupied_bytes(), 2048);

        let r2 = rb.read_bytes(&mut out).unwrap();
        assert_eq!(r2, 2048);
        assert_eq!(rb.occupied_bytes(), 0);
    }

    #[test]
    fn test_in_window_seek() {
        let rb = SpscRingBuffer::new(10 * 1024 * 1024);
        let epoch = rb.current_epoch();

        let data = vec![0x42u8; 64 * 1024];
        rb.write_chunk_sync(&data, epoch).unwrap();

        let fetches_before = rb.get_network_fetch_count();
        let mut out_pos = 0;
        let res = rb.seek(1024, 0, &mut out_pos);
        assert!(res.is_ok());
        assert_eq!(out_pos, 1024);
        assert_eq!(rb.get_network_fetch_count(), fetches_before);
    }

    #[test]
    fn test_out_of_window_seek() {
        let rb = SpscRingBuffer::new(10 * 1024 * 1024);
        let fetches_before = rb.get_network_fetch_count();

        let mut out_pos = 0;
        let res = rb.seek(2 * 1024 * 1024, 0, &mut out_pos);
        assert!(res.is_ok());
        assert_eq!(out_pos, 2 * 1024 * 1024);
        assert_eq!(rb.get_network_fetch_count(), fetches_before + 1);
    }

    #[test]
    fn test_timeout_on_empty() {
        let rb = SpscRingBuffer::new(1024);
        let mut buf = [0u8; 100];
        let res = rb.read_bytes(&mut buf);
        assert_eq!(res, Err(OMM_ERR_STREAM_TIMEOUT));
    }

    #[test]
    fn test_eof_on_empty() {
        let rb = SpscRingBuffer::new(1024);
        rb.set_eof();
        let mut buf = [0u8; 100];
        let res = rb.read_bytes(&mut buf);
        assert_eq!(res, Ok(0));
    }

    #[test]
    fn test_seek_post_wraparound_in_and_out_of_window() {
        let total_len = 10 * 1024 * 1024u64;
        let rb = SpscRingBuffer::new(total_len);
        let mut out = [0u8; 8192];

        // Stream 1 MB (exceeds 512KB capacity)
        let chunk = vec![0x33u8; 8192];
        for _ in 0..(1024 * 1024 / 8192) {
            rb.write_chunk_sync(&chunk, rb.current_epoch()).unwrap();
            rb.read_bytes(&mut out).unwrap();
        }

        assert_eq!(rb.current_position(), 1024 * 1024);
        assert_eq!(rb.occupied_bytes(), 0);

        // In-window micro-seek backward by 10KB
        let target_in = (1024 * 1024 - 10240) as i64;
        let mut out_pos = 0i64;
        let fetches_before = rb.get_network_fetch_count();
        let res = rb.seek(target_in, 0, &mut out_pos);
        assert_eq!(res, Ok(target_in));
        assert_eq!(out_pos, target_in);
        assert_eq!(rb.get_network_fetch_count(), fetches_before); // In-window hit
        assert_eq!(rb.occupied_bytes(), 10240); // Exactly 10KB available

        // Out-of-window seek backward to 50KB (overwritten)
        let target_out = 50_000i64;
        let res2 = rb.seek(target_out, 0, &mut out_pos);
        assert_eq!(res2, Ok(target_out));
        assert_eq!(out_pos, target_out);
        assert_eq!(rb.get_network_fetch_count(), fetches_before + 1); // Out-of-window flush
        assert_eq!(rb.occupied_bytes(), 0); // Flushed
    }
}
