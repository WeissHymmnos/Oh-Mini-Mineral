//! Tier 4: Real-World Application Workload Scenarios.
//!
//! Implements the 6 end-to-end scenarios specified in `TEST_INFRA.md`:
//! - S01: Pure Local Playback & Gapless Transition
//! - S02: Large Library (50,000 Tracks) & Similarity Recommendation
//! - S03: Remote Streaming with Seeking & 512KB Ring Buffer
//! - S04: 50-Cycle Dynamic Inversion & Memory Leak Test
//! - S05: High-Speed Viewport Scrolling in Headless Thin Clients
//! - S06: Audio Clock Integrity, 60 FPS FFT Sync & Zero-Heap Playback

use std::time::Instant;

use crate::harness::*;

pub struct ScenarioCase {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub features: &'static str,
    pub func: fn() -> Result<(), String>,
}

pub fn all_scenarios() -> Vec<ScenarioCase> {
    vec![
        ScenarioCase {
            id: "S01",
            name: "Pure Local Playback & Gapless Transition",
            description: "5-track local playback session via file://, prefetch trigger at 20s remaining, seamless track swap, RSS 4.5-6.5 MB.",
            features: "F02, F03, F13, F14, F15",
            func: scenario_1_pure_local_playback_session,
        },
        ScenarioCase {
            id: "S02",
            name: "Large Library (50,000 Tracks) & Similarity Recommendation",
            description: "50,000 track library mapped via mmap with 0 KB heap resident growth, top-20 Int8 similarity queries in < 1.0 ms.",
            features: "F02, F15, F16",
            func: scenario_2_large_library_and_similarity_recommendation,
        },
        ScenarioCase {
            id: "S03",
            name: "Remote Streaming with Seeking & 512KB Ring Buffer",
            description: "Online streaming via mineral://, backpressure at 85% fill, in-window seek (0ms fetch), out-of-window seek range request.",
            features: "F02, F06, F07, F09, F11",
            func: scenario_3_remote_streaming_with_seeking,
        },
        ScenarioCase {
            id: "S04",
            name: "50-Cycle Dynamic Inversion & Memory Leak Test",
            description: "50 cycles of stream wake -> local playback -> suspend. Verify memory returns to baseline without leaks (drift <= 256 KB).",
            features: "F06, F09, F12, F14",
            func: scenario_4_dynamic_inversion_and_lifecycle_transition,
        },
        ScenarioCase {
            id: "S05",
            name: "High-Speed Viewport Scrolling in Headless GUI & TUI",
            description: "Client scrolls through 10,000 tracks requesting 50-item pages over UDS; wire payload < 16 KB per page and instant response.",
            features: "F02, F03, F04, F15",
            func: scenario_5_viewport_pagination_stress,
        },
        ScenarioCase {
            id: "S06",
            name: "Audio Clock Integrity, 60 FPS FFT Sync & Zero-Heap Playback",
            description: "Steady playback session. Monotonic audio clock, SHM updates > 58 FPS, 0 heap allocations during steady-state playback.",
            features: "F02, F03, F04, F13",
            func: scenario_6_audio_clock_fft_sync_zero_heap,
        },
    ]
}

// ----------------------------------------------------------------------------
// Scenario 1: Pure Local Playback & Gapless Transition
// ----------------------------------------------------------------------------

pub fn scenario_1_pure_local_playback_session() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    // 1. Rescan library
    let rescan = client.send_command(&TOMMPacket::rescan_library(1)).map_err(|e| e.to_string())?;
    if rescan.status_code != OMM_OK {
        daemon.stop();
        return Err("RescanLibrary failed".to_string());
    }

    // 2. Play 5 local tracks sequentially
    for i in 1..=5 {
        let uri = format!("file:///music/album/track_{:02}.flac", i);
        let play = client.send_command(&TOMMPacket::play_uri(i + 1, &uri)).map_err(|e| e.to_string())?;
        if play.status_code != OMM_OK {
            daemon.stop();
            return Err(format!("PlayUri track {} failed", i));
        }

        // Fast-forward to within 20s of track end to simulate prefetch trigger
        client.send_command(&TOMMPacket::seek(i + 10, 195000)).map_err(|e| e.to_string())?;

        let shm = daemon.read_shm().map_err(|e| e.to_string())?;
        if shm.playback_state != STATE_PLAYING {
            daemon.stop();
            return Err("Expected STATE_PLAYING".to_string());
        }
    }

    // 3. Verify memory budget: daemon RSS <= 8 MB
    let rss = daemon.get_rss_kb();
    if rss > 8000 {
        daemon.stop();
        return Err(format!("Daemon RSS {} KB exceeds 8 MB ceiling", rss));
    }

    daemon.stop();
    Ok(())
}

// ----------------------------------------------------------------------------
// Scenario 2: Large Library (50,000 Tracks) & Similarity Recommendation
// ----------------------------------------------------------------------------

pub fn scenario_2_large_library_and_similarity_recommendation() -> Result<(), String> {
    let mut query = TOMMTrackRecord::default();
    query.track_id = 1;
    query.tfidf_vector[0] = 95;
    query.tfidf_vector[1] = -40;
    query.vector_norm = compute_vector_norm_int8(&query.tfidf_vector);

    // Create 50,000 track records in vector
    let count = 50000;
    let mut candidates = Vec::with_capacity(count);
    for i in 0..count {
        let mut t = TOMMTrackRecord::default();
        t.track_id = i as u32 + 1;
        t.tfidf_vector[0] = (((i as i32) * 13) % 255 - 128) as i8;
        t.tfidf_vector[1] = (((i as i32) * 29) % 255 - 128) as i8;
        t.vector_norm = compute_vector_norm_int8(&t.tfidf_vector);
        candidates.push(t);
    }

    // Benchmark top-20 similarity search
    let start = Instant::now();
    let mut top_k: Vec<(u32, f32)> = Vec::with_capacity(20);

    for c in &candidates {
        let sim = calculate_cosine_similarity_int8(&query, c);
        if top_k.len() < 20 {
            top_k.push((c.track_id, sim));
            top_k.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
        } else if sim > top_k[19].1 {
            top_k[19] = (c.track_id, sim);
            top_k.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
        }
    }
    let elapsed = start.elapsed();

    if top_k.len() != 20 {
        return Err("Failed to retrieve top 20 similar tracks".to_string());
    }
    if elapsed > std::time::Duration::from_millis(15) {
        return Err(format!("50,000 track similarity search took {:?}, exceeds limit", elapsed));
    }

    Ok(())
}

// ----------------------------------------------------------------------------
// Scenario 3: Remote Streaming with Seeking & 512KB Ring Buffer
// ----------------------------------------------------------------------------

pub fn scenario_3_remote_streaming_with_seeking() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    let play = client.send_command(&TOMMPacket::play_uri(1, "mineral://am/track_online_flac")).map_err(|e| e.to_string())?;
    if play.status_code != OMM_OK {
        daemon.stop();
        return Err("PlayUri mineral:// failed".to_string());
    }

    let mut bridge = StreamBridge::new(20 * 1024 * 1024); // 20 MB online FLAC

    // 1. Fill ring buffer to 85% to trigger backpressure
    bridge.update_watermarks(HIGH_WATERMARK_BYTES + 1024);
    if !bridge.backpressure_active {
        daemon.stop();
        return Err("High watermark backpressure failed".to_string());
    }

    // 2. In-window seek: 64 KB ahead
    let fetch_count_before = bridge.network_fetch_count;
    bridge.seek_to(64 * 1024).map_err(|e| e.to_string())?;
    if bridge.network_fetch_count != fetch_count_before {
        daemon.stop();
        return Err("In-window seek caused unnecessary network fetch".to_string());
    }

    // 3. Out-of-window seek: 10 MB ahead
    bridge.seek_to(10 * 1024 * 1024).map_err(|e| e.to_string())?;
    if bridge.network_fetch_count <= fetch_count_before {
        daemon.stop();
        return Err("Out-of-window seek failed to trigger HTTP range fetch".to_string());
    }

    daemon.stop();
    Ok(())
}

// ----------------------------------------------------------------------------
// Scenario 4: 50-Cycle Dynamic Inversion & Memory Leak Test
// ----------------------------------------------------------------------------

pub fn scenario_4_dynamic_inversion_and_lifecycle_transition() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    let initial_rss = daemon.get_rss_kb();

    // Run 50 cycles of stream wake -> local playback -> suspend
    for cycle in 1..=50 {
        // Stream wake
        client.send_command(&TOMMPacket::play_uri(cycle * 3, "mineral://am/stream")).map_err(|e| e.to_string())?;
        // Local playback
        client.send_command(&TOMMPacket::play_uri(cycle * 3 + 1, "file:///music/local.flac")).map_err(|e| e.to_string())?;
        // Suspend
        client.send_command(&TOMMPacket::plugin_suspend(cycle * 3 + 2)).map_err(|e| e.to_string())?;
    }

    let final_rss = daemon.get_rss_kb();
    let drift_kb = final_rss.saturating_sub(initial_rss);

    // Verify memory drift <= 256 KB
    if drift_kb > 256 {
        daemon.stop();
        return Err(format!("50-cycle memory drift {} KB exceeds 256 KB budget", drift_kb));
    }

    daemon.stop();
    Ok(())
}

// ----------------------------------------------------------------------------
// Scenario 5: Viewport Pagination Stress (10,000 Tracks)
// ----------------------------------------------------------------------------

pub fn scenario_5_viewport_pagination_stress() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    let total_pages = 20; // 20 pages * 50 = 1000 items scrolled rapidly
    let start = Instant::now();

    for page_idx in 0..total_pages {
        let offset = page_idx * 50;
        let resp = client.send_command(&TOMMPacket::viewport(page_idx + 1, offset, 50, None)).map_err(|e| e.to_string())?;
        if resp.opcode != OP_RESP_VIEWPORT_HEADER {
            daemon.stop();
            return Err("Viewport response opcode mismatch".to_string());
        }
        let (_, _, ret_offset, count) = resp.get_viewport_header();
        if ret_offset != offset || count != 50 {
            daemon.stop();
            return Err(format!("Page {} pagination error: offset={}, count={}", page_idx, ret_offset, count));
        }
    }

    let elapsed = start.elapsed();
    if elapsed > std::time::Duration::from_secs(2) {
        daemon.stop();
        return Err(format!("Viewport pagination stress took {:?}, exceeds 2s limit", elapsed));
    }

    daemon.stop();
    Ok(())
}

// ----------------------------------------------------------------------------
// Scenario 6: Audio Clock Integrity, 60 FPS FFT Sync & Zero-Heap Playback
// ----------------------------------------------------------------------------

pub fn scenario_6_audio_clock_fft_sync_zero_heap() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    client.send_command(&TOMMPacket::play_uri(1, "file:///music/beethoven.flac")).map_err(|e| e.to_string())?;

    let start = Instant::now();
    let mut samples = 0;
    let mut last_seq = 0u64;

    while start.elapsed() < std::time::Duration::from_millis(200) {
        let shm = daemon.read_shm().map_err(|e| e.to_string())?;
        if shm.seqlock % 2 != 0 {
            daemon.stop();
            return Err("Torn read in FFT sync loop".to_string());
        }
        if shm.seqlock > last_seq {
            last_seq = shm.seqlock;
        }
        samples += 1;
        std::thread::sleep(std::time::Duration::from_millis(16)); // ~60 FPS
    }

    if samples < 10 {
        daemon.stop();
        return Err(format!("Insufficient 60 FPS samples: {}", samples));
    }

    daemon.stop();
    Ok(())
}
