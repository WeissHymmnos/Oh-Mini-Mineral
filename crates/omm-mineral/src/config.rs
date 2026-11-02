//! Pure-Rust configuration parser for `daemon.lua`
//! Adapted from `crates/mineral-gui-core/src/daemon_config.rs` for headless plugin use.

use std::fs;
use std::path::PathBuf;

pub fn default_daemon_lua_path() -> PathBuf {
    if let Some(dir) = std::env::var_os("XDG_CONFIG_HOME") {
        return PathBuf::from(dir).join("mineral").join("daemon.lua");
    }
    if let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) {
        return PathBuf::from(home)
            .join(".config")
            .join("mineral")
            .join("daemon.lua");
    }
    PathBuf::from("daemon.lua")
}

#[derive(Clone, Debug, PartialEq)]
pub struct DaemonConfigData {
    // 1. Audio Engine (`audio.*`)
    pub audio_volume: u8,
    pub audio_backend: String,
    pub audio_playback_quality: String,
    pub audio_engine_tick_ms: u64,
    pub audio_pcm_buffer_ms: u64,
    pub audio_prefetch_bytes: u64,
    pub audio_tap_capacity: usize,

    // 2. Audio Cache (`cache.*`)
    pub cache_audio_capacity: u64,

    // 3. Download & Metadata Tagging (`download.*`)
    pub download_quality: String,
    pub download_dir: Option<String>,
    pub download_max_concurrent: usize,

    // 4. Sources (`sources.*`)
    pub sources_am_timeout_secs: u64,
    pub sources_am_proxy: Option<String>,
    pub sources_am_developer_token_cache_ttl_days: u32,
    pub sources_am_lyrics_translation_language: String,
    pub sources_am_lyrics_romanization_script: String,
    pub sources_am_media_concurrency: usize,
    pub sources_am_startup_buffer_secs: u64,

    pub sources_netease_timeout_secs: u64,
    pub sources_netease_proxy: Option<String>,
    pub sources_netease_max_connections: u64,
    pub sources_netease_playlist_batch_size: usize,
    pub sources_netease_playlist_max_concurrent: usize,

    pub sources_bilibili_timeout_secs: u64,
    pub sources_bilibili_proxy: Option<String>,
    pub sources_bilibili_max_connections: u64,

    pub sources_local_roots: Vec<String>,

    // 5. Playback Scheduling
    pub gapless_prefetch_ms: u64,
    pub prev_restart_threshold_ms: u64,
    pub player_tick_ms: u64,
}

impl Default for DaemonConfigData {
    fn default() -> Self {
        Self {
            audio_volume: 100,
            audio_backend: "auto".to_owned(),
            audio_playback_quality: "exhigh".to_owned(),
            audio_engine_tick_ms: 20,
            audio_pcm_buffer_ms: 200,
            audio_prefetch_bytes: 256 * 1024,
            audio_tap_capacity: 8192,

            cache_audio_capacity: 10 * 1024 * 1024 * 1024,

            download_quality: "lossless".to_owned(),
            download_dir: None,
            download_max_concurrent: 3,

            sources_am_timeout_secs: 100,
            sources_am_proxy: None,
            sources_am_developer_token_cache_ttl_days: 30,
            sources_am_lyrics_translation_language: "zh-hans-cn".to_owned(),
            sources_am_lyrics_romanization_script: "ja-Latn".to_owned(),
            sources_am_media_concurrency: 16,
            sources_am_startup_buffer_secs: 10,

            sources_netease_timeout_secs: 100,
            sources_netease_proxy: None,
            sources_netease_max_connections: 0,
            sources_netease_playlist_batch_size: 500,
            sources_netease_playlist_max_concurrent: 3,

            sources_bilibili_timeout_secs: 100,
            sources_bilibili_proxy: None,
            sources_bilibili_max_connections: 0,

            sources_local_roots: Vec::new(),

            gapless_prefetch_ms: 20000,
            prev_restart_threshold_ms: 3000,
            player_tick_ms: 20,
        }
    }
}

pub fn strip_lua_comment(line: &str) -> &str {
    let mut in_single = false;
    let mut in_double = false;
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'\\' && (in_single || in_double) {
            i += 2;
            continue;
        }
        if b == b'\'' && !in_double {
            in_single = !in_single;
        } else if b == b'"' && !in_single {
            in_double = !in_double;
        } else if !in_single && !in_double && b == b'-' && i + 1 < bytes.len() && bytes[i + 1] == b'-' {
            return &line[..i];
        }
        i += 1;
    }
    line
}

pub fn unquote_lua_str(raw: &str) -> Option<String> {
    let s = raw.trim().trim_end_matches(',').trim();
    if s == "nil" || s == "false" {
        return None;
    }
    if (s.starts_with('"') && s.ends_with('"') && s.len() >= 2)
        || (s.starts_with('\'') && s.ends_with('\'') && s.len() >= 2)
    {
        let inner = &s[1..s.len() - 1];
        return Some(
            inner
                .replace("\\\"", "\"")
                .replace("\\'", "'")
                .replace("\\\\", "\\"),
        );
    }
    None
}

pub fn parse_byte_size(raw: &str) -> Option<u64> {
    let s = raw.trim().trim_end_matches(',').trim();
    if let Ok(v) = s.parse::<u64>() {
        return Some(v);
    }
    // Support expressions like `256 * KB`, `10 * GB`, `512 MB`, `10GB`
    let upper = s.to_ascii_uppercase().replace('*', " ");
    let parts: Vec<&str> = upper.split_whitespace().collect();
    if parts.len() == 2 {
        let num = parts[0].parse::<f64>().ok()?;
        let mult: u64 = match parts[1] {
            "KB" | "K" | "KIB" => 1024,
            "MB" | "M" | "MIB" => 1024 * 1024,
            "GB" | "G" | "GIB" => 1024 * 1024 * 1024,
            "B" | "BYTES" => 1,
            _ => return None,
        };
        return Some((num * (mult as f64)).round() as u64);
    }
    for (suffix, mult) in [
        ("GIB", 1024u64 * 1024 * 1024),
        ("GB", 1024u64 * 1024 * 1024),
        ("MIB", 1024u64 * 1024),
        ("MB", 1024u64 * 1024),
        ("KIB", 1024u64),
        ("KB", 1024u64),
        ("G", 1024u64 * 1024 * 1024),
        ("M", 1024u64 * 1024),
        ("K", 1024u64),
        ("B", 1u64),
    ] {
        if let Some(prefix) = upper.strip_suffix(suffix) {
            if let Ok(num) = prefix.trim().parse::<f64>() {
                return Some((num * (mult as f64)).round() as u64);
            }
        }
    }
    None
}

pub fn parse_lua(content: &str) -> DaemonConfigData {
    let mut cfg = DaemonConfigData::default();
    let mut section_stack: Vec<String> = Vec::new();

    for raw_line in content.lines() {
        let line = strip_lua_comment(raw_line).trim();
        if line.is_empty() {
            continue;
        }

        // Section close: "}" or "},"
        if line == "}" || line == "}," {
            section_stack.pop();
            continue;
        }

        // Section open: e.g. "audio = {" or "sources = {" or "am = {"
        if let Some(idx) = line.find('{') {
            let prefix = line[..idx].trim().trim_end_matches('=').trim();
            if !prefix.is_empty() {
                section_stack.push(prefix.to_ascii_lowercase());
                continue;
            }
        }

        // Key-value pair: e.g. "pcm_buffer_ms = 400,"
        if let Some(eq_pos) = line.find('=') {
            let key = line[..eq_pos].trim().to_ascii_lowercase();
            let val = line[eq_pos + 1..].trim().trim_end_matches(',').trim();

            let section = section_stack.join(".");
            apply_kv(&mut cfg, &section, &key, val);
        }
    }

    // Boundary constraint: clamp audio_pcm_buffer_ms between [50, 5000]
    cfg.audio_pcm_buffer_ms = cfg.audio_pcm_buffer_ms.clamp(50, 5000);

    cfg
}

fn apply_kv(cfg: &mut DaemonConfigData, section: &str, key: &str, val: &str) {
    match (section, key) {
        ("audio", "volume") => {
            if let Ok(v) = val.parse::<u8>() {
                cfg.audio_volume = v.min(100);
            }
        }
        ("audio", "backend") => {
            if let Some(s) = unquote_lua_str(val) {
                cfg.audio_backend = s;
            }
        }
        ("audio", "playback_quality") => {
            if let Some(s) = unquote_lua_str(val) {
                cfg.audio_playback_quality = s;
            }
        }
        ("audio", "pcm_buffer_ms") => {
            if let Ok(v) = val.parse::<u64>() {
                cfg.audio_pcm_buffer_ms = v;
            }
        }
        ("audio", "prefetch_bytes") => {
            if let Some(v) = parse_byte_size(val) {
                cfg.audio_prefetch_bytes = v;
            }
        }
        ("cache", "audio_capacity") => {
            if let Some(v) = parse_byte_size(val) {
                cfg.cache_audio_capacity = v;
            }
        }
        ("sources.am", "timeout_secs") => {
            if let Ok(v) = val.parse::<u64>() {
                cfg.sources_am_timeout_secs = v;
            }
        }
        ("sources.am", "proxy") => {
            cfg.sources_am_proxy = unquote_lua_str(val);
        }
        ("sources.am", "media_concurrency") => {
            if let Ok(v) = val.parse::<usize>() {
                cfg.sources_am_media_concurrency = v;
            }
        }
        ("sources.am", "startup_buffer_secs") => {
            if let Ok(v) = val.parse::<u64>() {
                cfg.sources_am_startup_buffer_secs = v;
            }
        }
        ("sources.netease", "timeout_secs") => {
            if let Ok(v) = val.parse::<u64>() {
                cfg.sources_netease_timeout_secs = v;
            }
        }
        ("sources.netease", "proxy") => {
            cfg.sources_netease_proxy = unquote_lua_str(val);
        }
        ("sources.bilibili", "timeout_secs") => {
            if let Ok(v) = val.parse::<u64>() {
                cfg.sources_bilibili_timeout_secs = v;
            }
        }
        ("sources.bilibili", "proxy") => {
            cfg.sources_bilibili_proxy = unquote_lua_str(val);
        }
        ("", "gapless_prefetch_ms") => {
            if let Ok(v) = val.parse::<u64>() {
                cfg.gapless_prefetch_ms = v;
            }
        }
        _ => {}
    }
}

pub fn load_config_from_file_or_default(path_str: Option<&str>) -> DaemonConfigData {
    let path = match path_str {
        Some(s) if !s.is_empty() => PathBuf::from(s),
        _ => default_daemon_lua_path(),
    };

    if path.exists() {
        if let Ok(content) = fs::read_to_string(&path) {
            return parse_lua(&content);
        }
    }

    DaemonConfigData::default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_pcm_buffer_ms() {
        let lua = "audio = {\n    pcm_buffer_ms = 400,\n}\n";
        let cfg = parse_lua(lua);
        assert_eq!(cfg.audio_pcm_buffer_ms, 400);
    }

    #[test]
    fn test_clamp_pcm_buffer_ms() {
        let lua_zero = "audio = {\n    pcm_buffer_ms = 0,\n}\n";
        let cfg_zero = parse_lua(lua_zero);
        assert_eq!(cfg_zero.audio_pcm_buffer_ms, 50);

        let lua_huge = "audio = {\n    pcm_buffer_ms = 100000,\n}\n";
        let cfg_huge = parse_lua(lua_huge);
        assert_eq!(cfg_huge.audio_pcm_buffer_ms, 5000);
    }

    #[test]
    fn test_sources_am_table() {
        let lua = r#"
sources = {
    am = {
        timeout_secs = 15,
        proxy = "http://127.0.0.1:8080",
        media_concurrency = 4,
    },
}
"#;
        let cfg = parse_lua(lua);
        assert_eq!(cfg.sources_am_timeout_secs, 15);
        assert_eq!(cfg.sources_am_proxy.as_deref(), Some("http://127.0.0.1:8080"));
        assert_eq!(cfg.sources_am_media_concurrency, 4);
    }

    #[test]
    fn test_parse_byte_size_expr() {
        assert_eq!(parse_byte_size("256 * KB"), Some(256 * 1024));
        assert_eq!(parse_byte_size("10 * GB"), Some(10 * 1024 * 1024 * 1024));
        assert_eq!(parse_byte_size("512 MB"), Some(512 * 1024 * 1024));
    }
}
