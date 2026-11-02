//! Empirical Challenger Stress Tests for Milestone 2 Iteration 2
//! Adversarial verification of:
//! 1. Dynamic sliding seek (in-window micro-seeks, out-of-window flushes to 50KB and 2,000,000B, byte oracle, occupancy <= 512KB)
//! 2. Lock contention during 200ms underrun (< 0.050 ms latency for get_status across 10,000 iterations)
//! 3. Background task termination and Arc<SpscRingBuffer> deallocation on close_stream under backpressure

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use omm_mineral::ring_buffer::{
    SpscRingBuffer, OMM_ERR_STREAM_TIMEOUT, RING_BUFFER_CAPACITY,
};
use omm_mineral::streaming::{PluginEngine, GLOBAL_ENGINE, OMM_OK};

#[inline]
fn expected_stream_byte(pos: u64) -> u8 {
    (((pos.wrapping_mul(17).wrapping_add(31)) ^ (pos >> 8)) & 0xFF) as u8
}

// ============================================================================
// 1. Dynamic Sliding Seek Stress with Byte-Accuracy Oracle
// ============================================================================
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn test_empirical_dynamic_sliding_seek_oracle() {
    let total_stream_len = 5 * 1024 * 1024u64; // 5 MB
    let rb = Arc::new(SpscRingBuffer::new(total_stream_len));

    // Producer task that produces deterministic bytes based on stream position
    let rb_writer = rb.clone();
    let producer_stop = Arc::new(AtomicBool::new(false));
    let stop_clone = producer_stop.clone();

    let producer_handle = tokio::spawn(async move {
        let chunk_size = 16384usize;
        let mut chunk = vec![0u8; chunk_size];

        while !stop_clone.load(Ordering::Relaxed) {
            let epoch = rb_writer.current_epoch();
            let base_pos = rb_writer.current_position() + rb_writer.occupied_bytes() as u64;

            if base_pos >= total_stream_len {
                tokio::time::sleep(Duration::from_millis(5)).await;
                continue;
            }

            let to_write = ((total_stream_len - base_pos) as usize).min(chunk_size);
            for i in 0..to_write {
                chunk[i] = expected_stream_byte(base_pos + i as u64);
            }

            match rb_writer.write_chunk(&chunk[..to_write], epoch).await {
                Ok(_) => {}
                Err(_) => {
                    // Epoch changed due to seek, loop around and query current_epoch
                    tokio::task::yield_now().await;
                }
            }
        }
    });

    // Step 1: Stream past 1MB of audio (1,200,000 bytes)
    let mut scratch = vec![0u8; 32768];
    let mut total_streamed = 0u64;

    while total_streamed < 1_200_000 {
        let to_read = (1_200_000 - total_streamed).min(scratch.len() as u64) as usize;
        match rb.read_bytes(&mut scratch[..to_read]) {
            Ok(n) => {
                for i in 0..n {
                    let actual = scratch[i];
                    let expected = expected_stream_byte(total_streamed + i as u64);
                    assert_eq!(actual, expected, "Data corruption during initial streaming at pos {}", total_streamed + i as u64);
                }
                total_streamed += n as u64;
                assert!(rb.occupied_bytes() <= RING_BUFFER_CAPACITY, "Occupancy exceeded 512KB!");
            }
            Err(OMM_ERR_STREAM_TIMEOUT) => {
                tokio::task::yield_now().await;
            }
            Err(e) => panic!("Unexpected read error: {}", e),
        }
    }

    println!("[DYNAMIC SEEK] Streamed {} bytes. Occupancy: {} B", total_streamed, rb.occupied_bytes());
    assert_eq!(rb.current_position(), 1_200_000);

    // Allow producer to top up buffer slightly
    tokio::time::sleep(Duration::from_millis(20)).await;

    let occ_before_micro = rb.occupied_bytes();
    let fetches_before_micro = rb.get_network_fetch_count();
    let epoch_before_micro = rb.current_epoch();

    // Step 2: In-window micro-seek BACKWARD by 32KB (1,200,000 -> 1,167,232)
    let target_backward = 1_200_000 - 32768i64;
    let mut out_pos = 0i64;
    let res = rb.seek(target_backward, 0 /* SEEK_SET */, &mut out_pos);
    assert_eq!(res, Ok(target_backward));
    assert_eq!(out_pos, target_backward);
    assert_eq!(rb.current_position(), target_backward as u64);

    // Verify In-Window invariants
    assert_eq!(rb.get_network_fetch_count(), fetches_before_micro, "In-window micro-seek backward triggered network fetch!");
    assert_eq!(rb.current_epoch(), epoch_before_micro, "In-window micro-seek backward changed epoch!");
    assert!(rb.occupied_bytes() <= RING_BUFFER_CAPACITY, "Occupancy exceeded 512KB on backward seek!");
    assert_eq!(rb.occupied_bytes(), occ_before_micro + 32768, "Occupancy did not expand by seek distance");

    // Verify audio bytes returned after backward seek (0 corruptions)
    let mut check_buf = [0u8; 1024];
    let n = rb.read_bytes(&mut check_buf).expect("Read failed after backward micro-seek");
    assert_eq!(n, 1024);
    for i in 0..1024 {
        assert_eq!(check_buf[i], expected_stream_byte(target_backward as u64 + i as u64), "Corruption after backward micro-seek at {}", i);
    }
    println!("  -> [PASS] In-window backward micro-seek returned exact audio bytes with 0 corruptions.");

    // Step 3: In-window micro-seek FORWARD by 16KB (from current 1,168,256 -> 1,184,640)
    let cur_pos = rb.current_position() as i64;
    let target_forward = cur_pos + 16384;
    let res = rb.seek(target_forward, 0 /* SEEK_SET */, &mut out_pos);
    assert_eq!(res, Ok(target_forward));
    assert_eq!(out_pos, target_forward);
    assert_eq!(rb.get_network_fetch_count(), fetches_before_micro, "In-window micro-seek forward triggered network fetch!");
    assert_eq!(rb.current_epoch(), epoch_before_micro, "In-window micro-seek forward changed epoch!");
    assert!(rb.occupied_bytes() <= RING_BUFFER_CAPACITY, "Occupancy exceeded 512KB on forward seek!");

    // Verify audio bytes returned after forward seek (0 corruptions)
    let n = rb.read_bytes(&mut check_buf).expect("Read failed after forward micro-seek");
    assert_eq!(n, 1024);
    for i in 0..1024 {
        assert_eq!(check_buf[i], expected_stream_byte(target_forward as u64 + i as u64), "Corruption after forward micro-seek at {}", i);
    }
    println!("  -> [PASS] In-window forward micro-seek returned exact audio bytes with 0 corruptions.");

    // Step 4: Out-of-window seek BACKWARD to byte 50,000 (past 1MB, overwritten)
    let target_50k = 50_000i64;
    let fetches_before_50k = rb.get_network_fetch_count();
    let epoch_before_50k = rb.current_epoch();

    let res = rb.seek(target_50k, 0 /* SEEK_SET */, &mut out_pos);
    assert_eq!(res, Ok(target_50k));
    assert_eq!(out_pos, target_50k);
    assert_eq!(rb.current_position(), 50_000);

    // Verify Out-of-Window invariants
    assert_eq!(rb.get_network_fetch_count(), fetches_before_50k + 1, "Seek to 50KB did not increment network fetch count!");
    assert_eq!(rb.current_epoch(), epoch_before_50k + 1, "Seek to 50KB did not advance epoch!");
    assert_eq!(rb.occupied_bytes(), 0, "Buffer was not flushed on out-of-window seek to 50KB!");
    println!("  -> [PASS] Out-of-window seek to 50KB cleanly flushed buffer and advanced epoch.");

    // Allow producer to resume and write new data at 50KB
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(rb.occupied_bytes() > 0, "Producer failed to resume streaming after seek to 50KB");

    let n = rb.read_bytes(&mut check_buf).expect("Read failed after resume from 50KB");
    assert_eq!(n, 1024);
    for i in 0..1024 {
        assert_eq!(check_buf[i], expected_stream_byte(50_000 + i as u64), "Corruption after resume from 50KB at {}", i);
    }
    println!("  -> [PASS] Audio streaming cleanly resumed at byte 50,000 with 0 corruptions.");

    // Step 5: Out-of-window seek FORWARD to future byte 2,000,000
    let target_2m = 2_000_000i64;
    let fetches_before_2m = rb.get_network_fetch_count();
    let epoch_before_2m = rb.current_epoch();

    let res = rb.seek(target_2m, 0 /* SEEK_SET */, &mut out_pos);
    assert_eq!(res, Ok(target_2m));
    assert_eq!(out_pos, target_2m);
    assert_eq!(rb.current_position(), 2_000_000);

    // Verify Out-of-Window invariants
    assert_eq!(rb.get_network_fetch_count(), fetches_before_2m + 1, "Seek to 2MB did not increment network fetch count!");
    assert_eq!(rb.current_epoch(), epoch_before_2m + 1, "Seek to 2MB did not advance epoch!");
    assert_eq!(rb.occupied_bytes(), 0, "Buffer was not flushed on out-of-window seek to 2MB!");
    println!("  -> [PASS] Out-of-window seek to 2MB cleanly flushed buffer and advanced epoch.");

    // Allow producer to resume and write new data at 2MB
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(rb.occupied_bytes() > 0, "Producer failed to resume streaming after seek to 2MB");

    let n = rb.read_bytes(&mut check_buf).expect("Read failed after resume from 2MB");
    assert_eq!(n, 1024);
    for i in 0..1024 {
        assert_eq!(check_buf[i], expected_stream_byte(2_000_000 + i as u64), "Corruption after resume from 2MB at {}", i);
    }
    println!("  -> [PASS] Audio streaming cleanly resumed at byte 2,000,000 with 0 corruptions.");

    producer_stop.store(true, Ordering::Relaxed);
    rb.close();
    let _ = producer_handle.await;
}

// ============================================================================
// 2. Lock Contention Verification During 200ms Underrun (< 0.050 ms latency)
// ============================================================================
#[test]
fn test_empirical_lock_contention_during_underrun() {
    let mut engine = PluginEngine::new();
    engine.init(None);

    let handle_id = engine.open_stream("mineral://stream/underrun_lock_bench").expect("Open failed");
    let session = engine.get_stream(handle_id).expect("Stream missing");

    // Put GLOBAL_ENGINE in place so get_status tests real lock path
    {
        let mut lock = GLOBAL_ENGINE.write();
        *lock = Some(engine);
    }

    // Spawn reader thread that blocks in 200ms underrun
    let session_clone = session.clone();
    let reader_thread = std::thread::spawn(move || {
        let mut buf = [0u8; 1024];
        let t0 = Instant::now();
        let res = session_clone.read_bytes(&mut buf);
        let elapsed = t0.elapsed();
        (res, elapsed)
    });

    // Wait 40ms to ensure reader is blocked inside read_bytes waiting on empty_condvar
    std::thread::sleep(Duration::from_millis(40));

    // Execute 10,000 rapid concurrent get_status() calls while reader is blocked
    const CALLS: usize = 10_000;
    let mut latencies_us = Vec::with_capacity(CALLS);

    let bench_start = Instant::now();
    for _ in 0..CALLS {
        let t_call = Instant::now();
        let status = {
            let lock = GLOBAL_ENGINE.read();
            let engine = lock.as_ref().unwrap();
            engine.get_status()
        };
        let call_duration = t_call.elapsed();
        latencies_us.push(call_duration.as_nanos() as f64 / 1000.0);
        assert_eq!(status.protocol_version, 0x00010000);
    }
    let total_bench_time = bench_start.elapsed();

    // Await reader thread
    let (read_res, read_elapsed) = reader_thread.join().expect("Reader panicked");
    assert_eq!(read_res, Err(OMM_ERR_STREAM_TIMEOUT));
    assert!(read_elapsed >= Duration::from_millis(185) && read_elapsed <= Duration::from_millis(215));

    latencies_us.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let min_us = latencies_us[0];
    let max_us = latencies_us[CALLS - 1];
    let mean_us: f64 = latencies_us.iter().sum::<f64>() / (CALLS as f64);
    let p95_us = latencies_us[(CALLS as f64 * 0.95) as usize];
    let p99_us = latencies_us[(CALLS as f64 * 0.99) as usize];

    let min_ms = min_us / 1000.0;
    let max_ms = max_us / 1000.0;
    let mean_ms = mean_us / 1000.0;
    let p99_ms = p99_us / 1000.0;

    println!("\n=== EMPIRICAL LOCK CONTENTION RESULTS ({} calls during 200ms underrun) ===", CALLS);
    println!("  Total benchmark duration: {:.2?}", total_bench_time);
    println!("  Reader thread underrun duration: {:.3} ms (code: {:?})", read_elapsed.as_secs_f64() * 1000.0, read_res);
    println!("  get_status() Latencies:");
    println!("    Min:  {:.4} ms ({:.2} µs)", min_ms, min_us);
    println!("    Mean: {:.4} ms ({:.2} µs)", mean_ms, mean_us);
    println!("    P95:  {:.4} ms ({:.2} µs)", p95_us / 1000.0, p95_us);
    println!("    P99:  {:.4} ms ({:.2} µs)", p99_ms, p99_us);
    println!("    Max:  {:.4} ms ({:.2} µs)", max_ms, max_us);

    // Strictly enforce requirement: get_status latency < 0.050 ms (50 µs)
    let threshold_ms = 0.050;
    let threshold_us = 50.0;
    assert!(
        p99_us < threshold_us,
        "P99 latency {:.3} µs exceeded 50.0 µs (0.050 ms) threshold!",
        p99_us
    );
    assert!(
        mean_us < 5.0,
        "Mean latency {:.3} µs exceeded expected non-blocking bound (5.0 µs)",
        mean_us
    );
    assert!(
        max_ms < threshold_ms,
        "Max latency {:.4} ms exceeded 0.050 ms threshold!",
        max_ms
    );
    println!("  -> [PASS] Verified get_status is strictly non-blocking with max latency < 0.050 ms (Max: {:.4} ms)", max_ms);

    // Clean up
    let mut lock = GLOBAL_ENGINE.write();
    if let Some(mut engine) = lock.take() {
        engine.close_stream(handle_id);
        engine.shutdown();
    }
}

// ============================================================================
// 3. Task Lifecycle Verification & Arc Deallocation Oracle
// ============================================================================
#[test]
fn test_empirical_task_lifecycle_and_arc_deallocation() {
    let mut engine = PluginEngine::new();
    engine.init(None);

    let handle_id = engine.open_stream("mineral://stream/backpressure_dealloc_test").expect("Open failed");

    // Wait 50ms for background producer to stream 445KB+ and pause in backpressure
    std::thread::sleep(Duration::from_millis(50));

    let rb = {
        let session = engine.get_stream(handle_id).expect("Stream missing");
        assert!(session.ring_buffer.is_backpressure_active(), "Producer should be in backpressure");
        assert!(session.ring_buffer.occupied_bytes() >= omm_mineral::ring_buffer::HIGH_WATERMARK_BYTES);
        session.ring_buffer.clone()
    };

    // Create a Weak pointer to the ring buffer before closing
    let weak_rb = Arc::downgrade(&rb);
    assert!(weak_rb.upgrade().is_some());

    // Measure close_stream latency
    let t_close = Instant::now();
    let rc = engine.close_stream(handle_id);
    let close_elapsed = t_close.elapsed();

    assert_eq!(rc, OMM_OK);
    println!("\n=== TASK LIFECYCLE & DEALLOCATION BENCHMARK ===");
    println!("  close_stream() execution time: {:.3} µs", close_elapsed.as_nanos() as f64 / 1000.0);
    assert!(close_elapsed < Duration::from_millis(5), "close_stream took > 5ms: {:?}", close_elapsed);

    // Drop our local Arc clone. Now the ONLY possible remaining holder is the background Tokio task
    drop(rb);

    // Check background task termination speed
    let wait_start = Instant::now();
    let mut terminated = false;
    while wait_start.elapsed() < Duration::from_millis(50) {
        if weak_rb.upgrade().is_none() {
            terminated = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    let termination_elapsed = wait_start.elapsed();

    println!("  Background task terminated and Arc deallocated in: {:.2?}", termination_elapsed);

    assert!(terminated, "Background task failed to exit within 50ms! Arc<SpscRingBuffer> still retained!");
    assert!(weak_rb.upgrade().is_none(), "Memory leak: Arc<SpscRingBuffer> not deallocated!");
    assert_eq!(engine.active_streams.load(Ordering::Acquire), 0, "active_streams != 0");
    println!("  -> [PASS] Task terminated in < 50ms ({:.2?}) and Arc<SpscRingBuffer> completely deallocated.", termination_elapsed);

    engine.shutdown();
}
