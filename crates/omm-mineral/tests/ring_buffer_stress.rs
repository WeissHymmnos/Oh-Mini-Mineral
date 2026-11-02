//! Empirical Stress Test Harness for SPSC Ring Buffer, Backpressure, Underrun Guard & Seek Logic
//! Milestone 2 Challenger 1: Adversarial Verification

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use omm_mineral::ring_buffer::{
    SpscRingBuffer, HIGH_WATERMARK_BYTES, LOW_WATERMARK_BYTES, OMM_ERR_STREAM_TIMEOUT,
    RING_BUFFER_CAPACITY,
};

/// Deterministic LCG pseudo-random byte generator
#[inline]
fn lcg_next(state: &mut u64) -> u8 {
    *state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    (*state >> 33) as u8
}

// ============================================================================
// 1. SPSC Throughput & Data Integrity Stress Tests
// ============================================================================

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_throughput_and_integrity_100mb_symmetric() {
    run_throughput_integrity_test(100 * 1024 * 1024, 8192, 8192).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_throughput_and_integrity_asymmetric_large_write_small_read() {
    run_throughput_integrity_test(30 * 1024 * 1024, 65536, 1024).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_throughput_and_integrity_asymmetric_small_write_large_read() {
    run_throughput_integrity_test(30 * 1024 * 1024, 1024, 65536).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_throughput_and_integrity_unaligned_chunk_sizes() {
    run_throughput_integrity_test(20 * 1024 * 1024, 13337, 7777).await;
}

async fn run_throughput_integrity_test(
    total_bytes: usize,
    write_chunk_size: usize,
    read_chunk_size: usize,
) {
    let rb = Arc::new(SpscRingBuffer::new(total_bytes as u64));
    let start_seed = 0xDEADBEEF_CAFE1234u64;

    let rb_writer = rb.clone();
    let writer_handle = tokio::spawn(async move {
        let mut prng = start_seed;
        let mut buffer = vec![0u8; write_chunk_size];
        let mut remaining = total_bytes;

        while remaining > 0 {
            let this_chunk = remaining.min(write_chunk_size);
            for b in buffer[..this_chunk].iter_mut() {
                *b = lcg_next(&mut prng);
            }

            let epoch = rb_writer.current_epoch();
            let mut offset = 0;
            while offset < this_chunk {
                match rb_writer.write_chunk(&buffer[offset..this_chunk], epoch).await {
                    Ok(n) => {
                        offset += n;
                    }
                    Err(e) => {
                        panic!("Writer encountered error: {}", e);
                    }
                }
            }
            remaining -= this_chunk;
        }
        rb_writer.set_eof();
    });

    let rb_reader = rb.clone();
    let reader_handle = tokio::task::spawn_blocking(move || {
        let mut prng = start_seed;
        let mut read_buf = vec![0u8; read_chunk_size];
        let mut total_read = 0usize;
        let mut corruptions = 0usize;

        let start_time = Instant::now();

        loop {
            match rb_reader.read_bytes(&mut read_buf) {
                Ok(0) => {
                    break; // EOF
                }
                Ok(n) => {
                    for i in 0..n {
                        let expected = lcg_next(&mut prng);
                        if read_buf[i] != expected {
                            corruptions += 1;
                        }
                    }
                    total_read += n;
                }
                Err(e) => {
                    panic!("Reader encountered error: {}", e);
                }
            }
        }

        let elapsed = start_time.elapsed();
        (total_read, corruptions, elapsed)
    });

    let _ = writer_handle.await.expect("Writer task failed");
    let (total_read, corruptions, elapsed) = reader_handle.await.expect("Reader task failed");

    let mb = (total_read as f64) / (1024.0 * 1024.0);
    let sec = elapsed.as_secs_f64();
    let mb_per_sec = mb / sec;

    println!(
        "[THROUGHPUT] Total: {:.2} MB, Elapsed: {:.3} s, Rate: {:.2} MB/s, Corruptions: {}, WriteChunk: {}, ReadChunk: {}",
        mb, sec, mb_per_sec, corruptions, write_chunk_size, read_chunk_size
    );

    assert_eq!(total_read, total_bytes, "Read count mismatch");
    assert_eq!(corruptions, 0, "Data corruption detected in ring buffer stream");
}

// ============================================================================
// 2. Backpressure Watermark Transition Stress Tests (85% Pause, 40% Resume)
// ============================================================================

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_backpressure_transitions_slow_reader() {
    let total_bytes = 10 * 1024 * 1024; // 10 MB
    let rb = Arc::new(SpscRingBuffer::new(total_bytes as u64));

    let bp_pauses = Arc::new(AtomicUsize::new(0));
    let bp_resumes = Arc::new(AtomicUsize::new(0));
    let max_occupied = Arc::new(AtomicUsize::new(0));

    let rb_writer = rb.clone();
    let bp_pauses_clone = bp_pauses.clone();
    let max_occupied_clone = max_occupied.clone();

    let writer_handle = tokio::spawn(async move {
        let chunk = vec![0xAAu8; 8192];
        let mut written_total = 0usize;
        let mut was_backpressured = false;

        while written_total < total_bytes {
            let occ = rb_writer.occupied_bytes();
            let mut cur_max = max_occupied_clone.load(Ordering::Relaxed);
            while occ > cur_max {
                match max_occupied_clone.compare_exchange_weak(cur_max, occ, Ordering::Relaxed, Ordering::Relaxed) {
                    Ok(_) => break,
                    Err(actual) => cur_max = actual,
                }
            }

            let is_bp = rb_writer.is_backpressure_active();
            if is_bp && !was_backpressured {
                bp_pauses_clone.fetch_add(1, Ordering::SeqCst);
                was_backpressured = true;
            } else if !is_bp && was_backpressured {
                was_backpressured = false;
            }

            let epoch = rb_writer.current_epoch();
            let to_write = (total_bytes - written_total).min(chunk.len());
            match rb_writer.write_chunk(&chunk[..to_write], epoch).await {
                Ok(n) => written_total += n,
                Err(e) => panic!("Writer failed: {}", e),
            }
        }
        rb_writer.set_eof();
    });

    let rb_reader = rb.clone();
    let bp_resumes_clone = bp_resumes.clone();

    let reader_handle = tokio::task::spawn_blocking(move || {
        let mut buf = vec![0u8; 4096];
        let mut total_read = 0usize;

        while total_read < total_bytes {
            // Mismatched speed: deliberate slow reader
            std::thread::sleep(Duration::from_micros(50));

            let occ_before = rb_reader.occupied_bytes();
            let is_bp_before = rb_reader.is_backpressure_active();

            match rb_reader.read_bytes(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    total_read += n;
                    let is_bp_after = rb_reader.is_backpressure_active();
                    let occ_after = rb_reader.occupied_bytes();

                    if is_bp_before && !is_bp_after {
                        bp_resumes_clone.fetch_add(1, Ordering::SeqCst);
                        // Verify watermark invariant: resume MUST occur at or below 40% (209,715)
                        assert!(
                            occ_after <= LOW_WATERMARK_BYTES,
                            "Backpressure resumed at {} bytes, which is > LOW_WATERMARK_BYTES ({})",
                            occ_after,
                            LOW_WATERMARK_BYTES
                        );
                    }

                    if is_bp_after {
                        // While backpressure is active, occupied must have reached at least 85%
                        assert!(
                            occ_before >= LOW_WATERMARK_BYTES,
                            "Backpressure active with only {} bytes in buffer",
                            occ_before
                        );
                    }
                }
                Err(e) => panic!("Reader failed: {}", e),
            }
        }
        total_read
    });

    let _ = writer_handle.await.expect("Writer task failed");
    let total_read = reader_handle.await.expect("Reader task failed");

    let pauses = bp_pauses.load(Ordering::SeqCst);
    let resumes = bp_resumes.load(Ordering::SeqCst);
    let peak_occ = max_occupied.load(Ordering::SeqCst);

    println!(
        "[BACKPRESSURE SLOW READER] Read: {} B, Pauses (observed by writer): {}, Resumes (<=40% observed by reader): {}, Peak Occupancy: {} B / {} B ({:.1}%)",
        total_read,
        pauses,
        resumes,
        peak_occ,
        RING_BUFFER_CAPACITY,
        (peak_occ as f64 / RING_BUFFER_CAPACITY as f64) * 100.0
    );

    assert_eq!(total_read, total_bytes);
    assert!(resumes >= 10, "Expected at least 10 backpressure resume events under slow reader, got {}", resumes);
    assert!(peak_occ <= RING_BUFFER_CAPACITY, "Buffer overflow: peak occupied {} > capacity {}", peak_occ, RING_BUFFER_CAPACITY);
    assert!(peak_occ >= HIGH_WATERMARK_BYTES, "Peak occupancy never reached high watermark");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_backpressure_transitions_bursty_reader() {
    let total_bytes = 10 * 1024 * 1024; // 10 MB
    let rb = Arc::new(SpscRingBuffer::new(total_bytes as u64));

    let rb_writer = rb.clone();
    let writer_handle = tokio::spawn(async move {
        let chunk = vec![0xBBu8; 16384];
        let mut written_total = 0usize;

        while written_total < total_bytes {
            let epoch = rb_writer.current_epoch();
            let to_write = (total_bytes - written_total).min(chunk.len());
            match rb_writer.write_chunk(&chunk[..to_write], epoch).await {
                Ok(n) => written_total += n,
                Err(e) => panic!("Writer failed: {}", e),
            }
        }
        rb_writer.set_eof();
    });

    let rb_reader = rb.clone();
    let reader_handle = tokio::task::spawn_blocking(move || {
        let mut total_read = 0usize;
        let mut cycles = 0;

        while total_read < total_bytes {
            // Wait for buffer to hit backpressure
            let wait_start = Instant::now();
            while !rb_reader.is_backpressure_active() && !rb_reader.is_eof() && wait_start.elapsed() < Duration::from_millis(50) {
                std::thread::sleep(Duration::from_millis(1));
            }

            // Bursty read: drain 300 KB in one go
            let mut burst_buf = vec![0u8; 300 * 1024];
            match rb_reader.read_bytes(&mut burst_buf) {
                Ok(0) => break,
                Ok(n) => {
                    total_read += n;
                    cycles += 1;
                    // Immediately after reading 300KB from >= 85% (445KB), remaining is <= 145KB (<= 40%),
                    // so backpressure MUST have cleared!
                    let occ = rb_reader.occupied_bytes();
                    if occ <= LOW_WATERMARK_BYTES {
                        assert!(
                            !rb_reader.is_backpressure_active(),
                            "Backpressure still active when occupied is {} <= LOW_WATERMARK ({})",
                            occ,
                            LOW_WATERMARK_BYTES
                        );
                    }
                }
                Err(e) => panic!("Reader error: {}", e),
            }
        }
        (total_read, cycles)
    });

    let _ = writer_handle.await.expect("Writer failed");
    let (total_read, cycles) = reader_handle.await.expect("Reader failed");

    println!("[BACKPRESSURE BURSTY READER] Read: {} B, Burst Cycles: {}", total_read, cycles);
    assert_eq!(total_read, total_bytes);
    assert!(cycles >= 15, "Expected at least 15 burst cycles, got {}", cycles);
}

// ============================================================================
// 3. 200ms Read Timeout Underrun Defense Stress Tests
// ============================================================================

#[test]
fn test_read_timeout_accuracy_and_stability() {
    let rb = SpscRingBuffer::new(10 * 1024 * 1024);
    let mut buf = [0u8; 1024];

    let mut elapsed_times = Vec::new();

    for iteration in 0..10 {
        let t0 = Instant::now();
        let res = rb.read_bytes(&mut buf);
        let elapsed = t0.elapsed();
        let elapsed_ms = elapsed.as_secs_f64() * 1000.0;

        elapsed_times.push(elapsed_ms);

        assert_eq!(res, Err(OMM_ERR_STREAM_TIMEOUT), "Iteration {} did not return timeout", iteration);

        // Verification requirement: 200ms +/- 15ms -> [185.0ms, 215.0ms]
        println!("Iteration {}: elapsed = {:.3} ms (target 200.0 +/- 15.0 ms)", iteration, elapsed_ms);
        assert!(
            elapsed_ms >= 185.0 && elapsed_ms <= 215.0,
            "Iteration {}: timeout {:.3} ms outside tolerance [185.0, 215.0] ms",
            iteration,
            elapsed_ms
        );
    }

    let min = elapsed_times.iter().cloned().fold(f64::INFINITY, f64::min);
    let max = elapsed_times.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let mean = elapsed_times.iter().sum::<f64>() / (elapsed_times.len() as f64);

    println!("[TIMEOUT STATS] Min: {:.2} ms, Max: {:.2} ms, Mean: {:.2} ms across 10 iterations", min, max, mean);
    assert!(mean >= 195.0 && mean <= 205.0, "Mean timeout {:.2} ms drifted outside nominal window", mean);
}

#[test]
fn test_underrun_recovery_after_timeout() {
    let rb = SpscRingBuffer::new(10 * 1024 * 1024);
    let mut buf = [0u8; 1024];

    // 1. First read on empty buffer -> timeout
    let t0 = Instant::now();
    let res = rb.read_bytes(&mut buf);
    let elapsed = t0.elapsed();
    assert_eq!(res, Err(OMM_ERR_STREAM_TIMEOUT));
    assert!(elapsed.as_millis() >= 185 && elapsed.as_millis() <= 215);

    // 2. Producer recovers and writes data
    let test_data = vec![0x33u8; 4096];
    let written = rb.write_chunk_sync(&test_data, 0).expect("Write failed");
    assert_eq!(written, 4096);

    // 3. Second read -> must succeed IMMEDIATELY without timeout
    let t1 = Instant::now();
    let res2 = rb.read_bytes(&mut buf);
    let elapsed2 = t1.elapsed();

    assert_eq!(res2, Ok(1024));
    assert_eq!(buf[0], 0x33);
    assert!(elapsed2.as_millis() < 5, "Recovery read took too long: {:?}", elapsed2);
    println!("[UNDERRUN RECOVERY] Immediate read after timeout succeeded in {:?}", elapsed2);
}

// ============================================================================
// 4. Seek Stress, Boundary Violations & Desynchronization
// ============================================================================

#[test]
fn test_seek_in_window_before_buffer_wraparound() {
    let rb = SpscRingBuffer::new(10 * 1024 * 1024);
    let mut data = vec![0u8; 100_000];
    for (i, b) in data.iter_mut().enumerate() {
        *b = (i & 0xFF) as u8;
    }

    rb.write_chunk_sync(&data, 0).unwrap();

    let mut buf = vec![0u8; 50_000];
    let r = rb.read_bytes(&mut buf).unwrap();
    assert_eq!(r, 50_000);
    assert_eq!(rb.current_position(), 50_000);

    // Seek back to position 10,000 (SEEK_SET)
    let mut out_pos = 0i64;
    let res = rb.seek(10_000, 0, &mut out_pos);
    assert_eq!(res, Ok(10_000));
    assert_eq!(out_pos, 10_000);

    // Read 10 bytes from position 10,000
    let mut check_buf = [0u8; 10];
    rb.read_bytes(&mut check_buf).unwrap();
    for (i, &b) in check_buf.iter().enumerate() {
        assert_eq!(b, ((10_000 + i) & 0xFF) as u8, "Byte mismatch after in-window seek");
    }
}

/// Adversarial Test: Test Seek Behavior AFTER the circular buffer has wrapped around (> 512KB).
/// This tests whether `seek` produces corrupted data or breaks occupied byte invariants.
#[test]
fn test_seek_after_buffer_wraparound_corruption_oracle() {
    let total_stream_len = 10 * 1024 * 1024u64;
    let rb = SpscRingBuffer::new(total_stream_len);

    // Stream 1,000,000 bytes (> 512 KB capacity) through the ring buffer
    // Pattern: byte value is non-repeating across 512KB: ((offset >> 16) ^ (offset >> 8) ^ offset) & 0xFF
    let stream_bytes = 1_000_000usize;
    let chunk_size = 32768usize;
    let mut current_offset = 0usize;

    let mut chunk = vec![0u8; chunk_size];
    let mut read_scratch = vec![0u8; chunk_size];

    let pattern_fn = |off: usize| -> u8 {
        (((off >> 16) ^ (off >> 8) ^ off) & 0xFF) as u8
    };

    while current_offset < stream_bytes {
        let to_push = (stream_bytes - current_offset).min(chunk_size);
        for i in 0..to_push {
            chunk[i] = pattern_fn(current_offset + i);
        }

        let w = rb.write_chunk_sync(&chunk[..to_push], 0).unwrap();
        // Concurrently consume so buffer doesn't overflow
        let r = rb.read_bytes(&mut read_scratch[..w]).unwrap();
        assert_eq!(r, w);
        current_offset += w;
    }

    println!(
        "[SEEK WRAPAROUND] Streamed {} bytes. current_position = {}, occupied = {}",
        stream_bytes,
        rb.current_position(),
        rb.occupied_bytes()
    );

    // At this point, 1,000,000 bytes have been written and read.
    // The circular buffer only physically retains data from (1,000,000 - 524,288) = 475,712 to 1,000,000.
    // Bytes 0 .. 475,711 were completely OVERWRITTEN in memory.

    // CHALLENGE A (Micro-seek): 10KB backward seek from 1,000,000 to 990,000.
    // Byte 990,000 is 10KB behind 1,000,000 and is within the 512KB sliding window [475,712, 1,000,000].
    let mut out_pos = 0i64;
    let fetches_before_micro = rb.get_network_fetch_count();
    let seek_res = rb.seek(990_000, 0 /* SEEK_SET */, &mut out_pos);
    let fetches_after_micro = rb.get_network_fetch_count();

    println!(
        "[SEEK TO 990KB (MICRO-SEEK)] seek(990_000) returned {:?}, out_pos = {}, fetches_before = {}, fetches_after = {}",
        seek_res,
        out_pos,
        fetches_before_micro,
        fetches_after_micro
    );

    assert_eq!(seek_res, Ok(990_000));
    assert_eq!(out_pos, 990_000);
    assert_eq!(fetches_after_micro, fetches_before_micro, "Micro-seek to 990KB must be IN-WINDOW!");
    assert_eq!(rb.occupied_bytes(), 10000);

    // Verify data matches pattern at 990_000
    let mut sample_micro = [0u8; 10];
    let n_micro = rb.read_bytes(&mut sample_micro).unwrap();
    assert_eq!(n_micro, 10);
    for i in 0..10 {
        assert_eq!(sample_micro[i], pattern_fn(990_000 + i));
    }

    // CHALLENGE B (Out-of-window seek): Seek to byte 50,000.
    // Since 50,000 is overwritten, it MUST be recognized as OUT-OF-WINDOW (fetch count increments).
    let fetches_before_out = rb.get_network_fetch_count();
    let seek_res2 = rb.seek(50_000, 0 /* SEEK_SET */, &mut out_pos);
    let fetches_after_out = rb.get_network_fetch_count();

    println!(
        "[SEEK TO 50KB] seek(50_000) returned {:?}, out_pos = {}, fetches_before = {}, fetches_after = {}, occupied = {}",
        seek_res2,
        out_pos,
        fetches_before_out,
        fetches_after_out,
        rb.occupied_bytes()
    );

    assert_eq!(seek_res2, Ok(50_000));
    assert_eq!(out_pos, 50_000);
    assert_eq!(fetches_after_out, fetches_before_out + 1, "Seek to 50KB must be OUT-OF-WINDOW!");
    assert_eq!(rb.occupied_bytes(), 0, "Buffer must be flushed on out-of-window seek!");
}

/// Stress Test: Concurrent Streaming and Rapid Seeks
/// A producer is continuously pushing chunks to the ring buffer.
/// Concurrently, a consumer is reading and issuing random seeks (both in-window micro-seeks and out-of-window macro-seeks).
/// Verifies whether race conditions cause deadlocks, panic, or cursor corruption.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_concurrent_streaming_and_rapid_seeks() {
    let total_stream_len = 50 * 1024 * 1024u64; // 50 MB
    let rb = Arc::new(SpscRingBuffer::new(total_stream_len));
    let stop_signal = Arc::new(AtomicBool::new(false));

    let rb_writer = rb.clone();
    let stop_writer = stop_signal.clone();
    let writer_handle = tokio::spawn(async move {
        let chunk = vec![0x77u8; 8192];
        let mut current_pos = 0u64;

        while current_pos < total_stream_len && !stop_writer.load(Ordering::Relaxed) {
            let epoch = rb_writer.current_epoch();
            let to_write = (total_stream_len - current_pos).min(chunk.len() as u64) as usize;

            match rb_writer.write_chunk(&chunk[..to_write], epoch).await {
                Ok(n) => {
                    current_pos += n as u64;
                }
                Err(_) => {
                    // Epoch changed due to out-of-window seek
                    current_pos = rb_writer.current_position();
                }
            }
        }
    });

    let rb_reader = rb.clone();
    let stop_reader = stop_signal.clone();
    let reader_handle = tokio::task::spawn_blocking(move || {
        let mut buf = vec![0u8; 4096];
        let mut seek_count = 0usize;
        let mut reads = 0usize;

        let start = Instant::now();
        // Run seek hammer for 500ms
        while start.elapsed() < Duration::from_millis(500) {
            // Read some bytes
            let _ = rb_reader.read_bytes(&mut buf);
            reads += 1;

            if reads % 5 == 0 {
                // Perform a seek
                let cur = rb_reader.current_position();
                let mut out_pos = 0i64;
                if seek_count % 2 == 0 {
                    // In-window micro-seek (target near current)
                    let target = cur.saturating_sub(2048) as i64;
                    let _ = rb_reader.seek(target, 0 /* SEEK_SET */, &mut out_pos);
                } else {
                    // Out-of-window macro-seek (target far ahead)
                    let target = (cur + 2 * 1024 * 1024).min(total_stream_len - 10000) as i64;
                    let _ = rb_reader.seek(target, 0 /* SEEK_SET */, &mut out_pos);
                }
                seek_count += 1;
            }
        }

        stop_reader.store(true, Ordering::Relaxed);
        // An out-of-window seek invalidates epoch and unblocks any paused writer
        let mut out_pos = 0i64;
        let _ = rb_reader.seek(total_stream_len as i64, 0 /* SEEK_SET */, &mut out_pos);
        (reads, seek_count)
    });

    let (reads, seeks) = reader_handle.await.expect("Reader failed");
    let _ = writer_handle.await.expect("Writer failed");

    println!(
        "[CONCURRENT SEEK STRESS] Completed {} reads and {} concurrent seeks in 500ms without deadlock or panic.",
        reads, seeks
    );
    assert!(seeks >= 30, "Expected at least 30 seeks executed, got {}", seeks);
}

/// Verification Test: Simulates `close()` while producer is blocked on backpressure.
/// Verifies that `rb.close()` wakes the blocked writer task cleanly within 50ms without hang.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_cancellation_under_backpressure_clean_exit() {
    let rb = Arc::new(SpscRingBuffer::new(10 * 1024 * 1024));
    let rb_writer = rb.clone();

    let writer_task = tokio::spawn(async move {
        let chunk = vec![0x99u8; 8192];
        loop {
            let epoch = rb_writer.current_epoch();
            if rb_writer.write_chunk(&chunk, epoch).await.is_err() {
                break;
            }
        }
    });

    // Wait until producer is inside backpressure wait loop
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(rb.is_backpressure_active(), "Producer should be in backpressure");

    // Invoke clean close
    rb.close();

    // Verify writer task terminates cleanly within 50 milliseconds
    let wait_res = tokio::time::timeout(Duration::from_millis(50), writer_task).await;
    assert!(wait_res.is_ok(), "Writer task failed to exit within 50ms of rb.close()");
    let inner_res = wait_res.unwrap();
    assert!(inner_res.is_ok(), "Writer task panicked or failed");
    println!("Writer task exited cleanly on rb.close().");
}

/// Verification Test: Memory Reclamation & Arc Deallocation Oracle
#[test]
fn test_ring_buffer_arc_deallocation_on_close() {
    let mut engine = omm_mineral::PluginEngine::new();
    engine.init(None);
    let handle_id = engine.open_stream("mineral://stream/test_dealloc").expect("Open failed");

    // Allow streaming to start and reach backpressure
    std::thread::sleep(Duration::from_millis(50));

    let rb = {
        let session = engine.get_stream(handle_id).expect("Stream missing");
        session.ring_buffer.clone()
    };

    // Before close: strong_count is at least 2 (session map and our local rb clone, plus spawned task)
    assert!(Arc::strong_count(&rb) >= 2);

    // Close stream
    let rc = engine.close_stream(handle_id);
    assert_eq!(rc, 0);

    // Give Tokio task 20ms to exit and drop its clone
    std::thread::sleep(Duration::from_millis(20));

    // After close: only our local test clone should remain (strong_count == 1)
    assert_eq!(
        Arc::strong_count(&rb), 1,
        "Memory leak detected: Arc<SpscRingBuffer> still retained by background task!"
    );
}


