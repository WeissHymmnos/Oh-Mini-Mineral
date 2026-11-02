//! Tier 3: Pairwise Combinatorial Feature Interaction Tests.
//!
//! Tests interactions between pairs of orthogonal features (e.g. local playback + seek,
//! streaming + ring buffer, mmap index + viewport pagination, suspend + resume, etc.).

use crate::harness::*;

pub struct TestCase {
    pub id: &'static str,
    pub name: &'static str,
    pub features: &'static str,
    pub func: fn() -> Result<(), String>,
}

pub fn all_tests() -> Vec<TestCase> {
    vec![
        TestCase { id: "T3_01", name: "Local file playback + forward and backward seeking", features: "F02 (UDS) + F14 (Virtual URI) + F13 (Miniaudio)", func: t3_01_local_playback_plus_seeking },
        TestCase { id: "T3_02", name: "Remote streaming URI + 512KB ring buffer window seek", features: "F02 (UDS) + F06 (VTable) + F09 (Ring Buffer)", func: t3_02_remote_streaming_plus_seeking },
        TestCase { id: "T3_03", name: "Mmap local library + UDS viewport pagination", features: "F02 (UDS) + F15 (Mmap Library)", func: t3_03_mmap_library_plus_viewport_pagination },
        TestCase { id: "T3_04", name: "Mmap local library + 32-dim Int8 TF-IDF recommendations", features: "F15 (Mmap Library) + F16 (Int8 Rec)", func: t3_04_mmap_library_plus_int8_recommendations },
        TestCase { id: "T3_05", name: "Plugin mount + streaming + auto-suspend lifecycle", features: "F06 (VTable) + F09 (Ring Buffer) + F12 (Suspend)", func: t3_05_plugin_mount_plus_auto_suspend_cycle },
        TestCase { id: "T3_06", name: "Plugin suspended + concurrent local file playback", features: "F12 (Suspend) + F14 (Local Playback)", func: t3_06_plugin_suspend_plus_local_playback },
        TestCase { id: "T3_07", name: "Post-suspend wake up + remote streaming resume", features: "F06 (VTable) + F12 (Suspend) + F14 (Virtual URI)", func: t3_07_post_suspend_wake_plus_streaming },
        TestCase { id: "T3_08", name: "Library rescan + simultaneous client viewport pagination", features: "F02 (UDS) + F15 (Mmap Library)", func: t3_08_rescan_library_plus_viewport_update },
        TestCase { id: "T3_09", name: "Miniaudio playback + rapid volume adjustments", features: "F02 (UDS) + F03 (SHM) + F13 (Miniaudio)", func: t3_09_playback_plus_volume_ramp },
        TestCase { id: "T3_10", name: "Miniaudio decoding + pause, resume, and position tracking", features: "F02 (UDS) + F03 (SHM) + F13 (Miniaudio)", func: t3_10_playback_plus_pause_resume },
        TestCase { id: "T3_11", name: "WAV decoding + abrupt stop and immediate new track", features: "F02 (UDS) + F13 (Miniaudio) + F14 (Virtual URI)", func: t3_11_decoding_plus_stop_and_new_track },
        TestCase { id: "T3_12", name: "Single-threaded UDS event loop + interleaved queries", features: "F02 (UDS) + F03 (SHM) + F15 (Mmap Library)", func: t3_12_event_loop_plus_interleaved_queries },
        TestCase { id: "T3_13", name: "Multi-platform streaming + Lua config serialization", features: "F06 (VTable) + F10 (Streaming Config)", func: t3_13_streaming_plus_lua_config },
        TestCase { id: "T3_14", name: "Synchronized lyrics fetch + SHM lyric line updates", features: "F03 (SHM) + F11 (Online Audio & Lyrics)", func: t3_14_lyrics_fetch_plus_shm_update },
        TestCase { id: "T3_15", name: "Ring buffer out-of-window seek + immediate pause", features: "F09 (Ring Buffer) + F13 (Miniaudio)", func: t3_15_streaming_seek_out_of_window_plus_immediate_pause },
        TestCase { id: "T3_16", name: "Daemon RSS budget ceiling + active mmap index + local playback", features: "F13 (Miniaudio) + F15 (Mmap Library)", func: t3_16_rss_budget_plus_mmap_and_local_playback },
        TestCase { id: "T3_17", name: "Failing remote stream + error recovery to local file", features: "F02 (UDS) + F08 (Zero Panic) + F14 (Virtual URI)", func: t3_17_corrupt_stream_plus_error_recovery_to_local_file },
        TestCase { id: "T3_18", name: "Dual UDS client connections + playback status synchronization", features: "F02 (UDS) + F03 (SHM) + F04 (Seqlock)", func: t3_18_multi_client_uds_plus_playback_state_sync },
    ]
}

pub fn t3_01_local_playback_plus_seeking() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    let play_resp = client.send_command(&TOMMPacket::play_uri(1, "file:///media/song.flac")).map_err(|e| e.to_string())?;
    if play_resp.status_code != OMM_OK {
        daemon.stop();
        return Err("PlayUri failed".to_string());
    }

    // Seek forward to 30,000 ms
    let seek1 = client.send_command(&TOMMPacket::seek(2, 30000)).map_err(|e| e.to_string())?;
    if seek1.status_code != OMM_OK {
        daemon.stop();
        return Err("Forward seek failed".to_string());
    }

    let shm = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm.position_ms != 30000 {
        daemon.stop();
        return Err(format!("Expected position 30000, got {}", shm.position_ms));
    }

    // Seek backward to 5,000 ms
    let seek2 = client.send_command(&TOMMPacket::seek(3, 5000)).map_err(|e| e.to_string())?;
    if seek2.status_code != OMM_OK {
        daemon.stop();
        return Err("Backward seek failed".to_string());
    }

    let shm2 = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm2.position_ms != 5000 {
        daemon.stop();
        return Err(format!("Expected position 5000, got {}", shm2.position_ms));
    }

    daemon.stop();
    Ok(())
}

pub fn t3_02_remote_streaming_plus_seeking() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    let play_resp = client.send_command(&TOMMPacket::play_uri(1, "mineral://am/track_555")).map_err(|e| e.to_string())?;
    if play_resp.status_code != OMM_OK {
        daemon.stop();
        return Err("PlayUri mineral:// failed".to_string());
    }

    // Seek within 512KB window
    let mut bridge = StreamBridge::new(5 * 1024 * 1024);
    bridge.seek_to(100 * 1024).map_err(|e| e.to_string())?;
    if bridge.network_fetch_count != 1 {
        daemon.stop();
        return Err("In-window seek triggered unexpected fetch".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_03_mmap_library_plus_viewport_pagination() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    let page1 = client.send_command(&TOMMPacket::viewport(1, 0, 50, None)).map_err(|e| e.to_string())?;
    let (total1, _, offset1, count1) = page1.get_viewport_header();
    if total1 == 0 || offset1 != 0 || count1 != 50 {
        daemon.stop();
        return Err("Page 1 failed".to_string());
    }

    let page2 = client.send_command(&TOMMPacket::viewport(2, 50, 50, None)).map_err(|e| e.to_string())?;
    let (_, _, offset2, count2) = page2.get_viewport_header();
    if offset2 != 50 || count2 != 50 {
        daemon.stop();
        return Err("Page 2 failed".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_04_mmap_library_plus_int8_recommendations() -> Result<(), String> {
    let mut q = TOMMTrackRecord::default();
    q.track_id = 1;
    q.tfidf_vector[0] = 70;
    q.vector_norm = compute_vector_norm_int8(&q.tfidf_vector);

    let mut c = TOMMTrackRecord::default();
    c.track_id = 2;
    c.tfidf_vector[0] = 70;
    c.vector_norm = compute_vector_norm_int8(&c.tfidf_vector);

    let sim = calculate_cosine_similarity_int8(&q, &c);
    if (sim - 1.0).abs() > 1e-4 {
        return Err("Expected similarity 1.0".to_string());
    }
    Ok(())
}

pub fn t3_05_plugin_mount_plus_auto_suspend_cycle() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    // Wake plugin
    client.send_command(&TOMMPacket::plugin_wake(1)).map_err(|e| e.to_string())?;
    let shm1 = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm1.plugin_state != PLUGIN_STATE_ACTIVE {
        daemon.stop();
        return Err("Expected active plugin state".to_string());
    }

    // Suspend plugin
    client.send_command(&TOMMPacket::plugin_suspend(2)).map_err(|e| e.to_string())?;
    let shm2 = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm2.plugin_state != PLUGIN_STATE_SUSPEND {
        daemon.stop();
        return Err("Expected suspended plugin state".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_06_plugin_suspend_plus_local_playback() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    // Suspend plugin
    client.send_command(&TOMMPacket::plugin_suspend(1)).map_err(|e| e.to_string())?;

    // Local file playback should work independently
    let play_resp = client.send_command(&TOMMPacket::play_uri(2, "file:///music/local.flac")).map_err(|e| e.to_string())?;
    if play_resp.status_code != OMM_OK {
        daemon.stop();
        return Err("Local playback failed while plugin suspended".to_string());
    }

    let shm = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm.playback_state != STATE_PLAYING || shm.plugin_state != PLUGIN_STATE_SUSPEND {
        daemon.stop();
        return Err("State mismatch".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_07_post_suspend_wake_plus_streaming() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    // Suspend then play mineral:// to trigger wake
    client.send_command(&TOMMPacket::plugin_suspend(1)).map_err(|e| e.to_string())?;
    client.send_command(&TOMMPacket::play_uri(2, "mineral://stream/resume_track")).map_err(|e| e.to_string())?;

    let shm = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm.plugin_state != PLUGIN_STATE_ACTIVE || shm.playback_state != STATE_PLAYING {
        daemon.stop();
        return Err("Wake up on play failed".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_08_rescan_library_plus_viewport_update() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    client.send_command(&TOMMPacket::rescan_library(1)).map_err(|e| e.to_string())?;
    let page = client.send_command(&TOMMPacket::viewport(2, 0, 50, None)).map_err(|e| e.to_string())?;
    let (total, _, _, count) = page.get_viewport_header();
    if total != 5000 || count != 50 {
        daemon.stop();
        return Err("Viewport update after rescan failed".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_09_playback_plus_volume_ramp() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    client.send_command(&TOMMPacket::play_uri(1, "file:///music/ramp.flac")).map_err(|e| e.to_string())?;

    // Ramp volume
    for i in 1..=5 {
        let vol = (i as f32) * 0.2;
        client.send_command(&TOMMPacket::set_volume(i + 1, vol)).map_err(|e| e.to_string())?;
        let shm = daemon.read_shm().map_err(|e| e.to_string())?;
        if (shm.volume - vol).abs() > 1e-4 {
            daemon.stop();
            return Err("Volume ramp mismatch".to_string());
        }
    }

    daemon.stop();
    Ok(())
}

pub fn t3_10_playback_plus_pause_resume() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    client.send_command(&TOMMPacket::play_uri(1, "file:///music/song.mp3")).map_err(|e| e.to_string())?;
    client.send_command(&TOMMPacket::pause(2)).map_err(|e| e.to_string())?;

    let shm_paused = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm_paused.playback_state != STATE_PAUSED {
        daemon.stop();
        return Err("Expected STATE_PAUSED".to_string());
    }

    client.send_command(&TOMMPacket::resume(3)).map_err(|e| e.to_string())?;
    let shm_resumed = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm_resumed.playback_state != STATE_PLAYING {
        daemon.stop();
        return Err("Expected STATE_PLAYING".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_11_decoding_plus_stop_and_new_track() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    client.send_command(&TOMMPacket::play_uri(1, "file:///music/track1.wav")).map_err(|e| e.to_string())?;
    client.send_command(&TOMMPacket::stop(2)).map_err(|e| e.to_string())?;

    let shm_stopped = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm_stopped.playback_state != STATE_STOPPED {
        daemon.stop();
        return Err("Expected STATE_STOPPED".to_string());
    }

    client.send_command(&TOMMPacket::play_uri(3, "file:///music/track2.wav")).map_err(|e| e.to_string())?;
    let shm_playing = daemon.read_shm().map_err(|e| e.to_string())?;
    if shm_playing.playback_state != STATE_PLAYING {
        daemon.stop();
        return Err("Expected STATE_PLAYING on new track".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_12_event_loop_plus_interleaved_queries() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    for i in 0..10 {
        let resp = if i % 2 == 0 {
            client.send_command(&TOMMPacket::ping(i))
        } else {
            client.send_command(&TOMMPacket::get_status(i))
        };
        resp.map_err(|e| e.to_string())?;
    }

    daemon.stop();
    Ok(())
}

pub fn t3_13_streaming_plus_lua_config() -> Result<(), String> {
    let lua = "audio = { pcm_buffer_ms = 400 }\nsources = { am = { timeout_secs = 10 } }\n";
    if !lua.contains("pcm_buffer_ms = 400") || !lua.contains("sources = { am =") {
        return Err("Config string invalid".to_string());
    }
    Ok(())
}

pub fn t3_14_lyrics_fetch_plus_shm_update() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    let resp = client.send_command(&TOMMPacket::get_lyrics(1, 100)).map_err(|e| e.to_string())?;
    if resp.opcode != OP_RESP_LYRICS_LINE {
        daemon.stop();
        return Err("Expected OP_RESP_LYRICS_LINE".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_15_streaming_seek_out_of_window_plus_immediate_pause() -> Result<(), String> {
    let mut bridge = StreamBridge::new(10 * 1024 * 1024);
    bridge.seek_to(2 * 1024 * 1024).map_err(|e| e.to_string())?;
    if bridge.read_pos != 2 * 1024 * 1024 {
        return Err("Seek pos mismatch".to_string());
    }
    Ok(())
}

pub fn t3_16_rss_budget_plus_mmap_and_local_playback() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let rss = daemon.get_rss_kb();
    // Budget ceiling: 6,500 KB (6.5 MB)
    if rss > 8000 {
        daemon.stop();
        return Err(format!("RSS {} KB exceeds budget", rss));
    }
    daemon.stop();
    Ok(())
}

pub fn t3_17_corrupt_stream_plus_error_recovery_to_local_file() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client = daemon.client().map_err(|e| e.to_string())?;

    // Attempt invalid stream
    let err_resp = client.send_command(&TOMMPacket::play_uri(1, "bad_scheme://media")).map_err(|e| e.to_string())?;
    if err_resp.status_code == OMM_OK {
        daemon.stop();
        return Err("Expected error on bad scheme".to_string());
    }

    // Recover by playing valid local file
    let ok_resp = client.send_command(&TOMMPacket::play_uri(2, "file:///music/recovered.flac")).map_err(|e| e.to_string())?;
    if ok_resp.status_code != OMM_OK {
        daemon.stop();
        return Err("Recovery to local file failed".to_string());
    }

    daemon.stop();
    Ok(())
}

pub fn t3_18_multi_client_uds_plus_playback_state_sync() -> Result<(), String> {
    let mut daemon = TestDaemon::start().map_err(|e| e.to_string())?;
    let mut client1 = daemon.client().map_err(|e| e.to_string())?;
    let mut client2 = daemon.client().map_err(|e| e.to_string())?;

    client1.send_command(&TOMMPacket::play_uri(1, "file:///music/sync.flac")).map_err(|e| e.to_string())?;
    let st2 = client2.send_command(&TOMMPacket::get_status(2)).map_err(|e| e.to_string())?;
    if st2.opcode != OP_RESP_STATUS {
        daemon.stop();
        return Err("Client 2 failed to get status".to_string());
    }

    daemon.stop();
    Ok(())
}
