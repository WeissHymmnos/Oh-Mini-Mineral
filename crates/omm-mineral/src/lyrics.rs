//! Synchronized lyrics retrieval, formatting, and caller-buffer delivery.

use std::ffi::{c_char, CStr};
use std::ptr;

pub const OMM_OK: i32 = 0;
pub const OMM_ERR_INVALID_PARAM: i32 = -2;
pub const OMM_ERR_BUFFER_TOO_SMALL: i32 = -3;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LyricLine {
    pub timestamp_ms: u32,
    pub text: String,
}

/// Formats milliseconds into standard LRC timestamp `[mm:ss.xx]`.
pub fn format_lrc_timestamp(ms: u32) -> String {
    let minutes = ms / 60000;
    let seconds = (ms % 60000) / 1000;
    let hundredths = (ms % 1000) / 10;
    format!("[{:02}:{:02}.{:02}]", minutes, seconds, hundredths)
}

/// Parses an LRC timestamp `[mm:ss.xx]` into milliseconds.
pub fn parse_lrc_timestamp(tag: &str) -> Option<u32> {
    let trimmed = tag.trim();
    if !trimmed.starts_with('[') || !trimmed.ends_with(']') {
        return None;
    }
    let inner = &trimmed[1..trimmed.len() - 1];
    let parts: Vec<&str> = inner.split(':').collect();
    if parts.len() != 2 {
        return None;
    }
    let mins: u32 = parts[0].parse().ok()?;
    let sec_parts: Vec<&str> = parts[1].split('.').collect();
    if sec_parts.len() != 2 {
        return None;
    }
    let secs: u32 = sec_parts[0].parse().ok()?;
    let hundredths_str = sec_parts[1];
    let hundredths: u32 = match hundredths_str.len() {
        1 => hundredths_str.parse::<u32>().ok()? * 100,
        2 => hundredths_str.parse::<u32>().ok()? * 10,
        3 => hundredths_str.parse::<u32>().ok()?,
        _ => return None,
    };

    Some(mins * 60000 + secs * 1000 + hundredths)
}

/// Formats lyric lines into a monotonic LRC document.
pub fn to_lrc_string(lines: &[LyricLine]) -> String {
    let mut out = String::new();
    let mut last_ts = 0u32;
    for line in lines {
        let ts = line.timestamp_ms.max(last_ts);
        last_ts = ts;
        out.push_str(&format_lrc_timestamp(ts));
        out.push(' ');
        out.push_str(&line.text);
        out.push('\n');
    }
    out
}

/// Generates or resolves lyrics for a URI.
pub fn get_lyrics_for_uri(uri: &str) -> String {
    if uri.is_empty() {
        return String::new();
    }

    if let Some(rest) = uri.strip_prefix("netease://") {
        let song_id = rest.strip_prefix("track/").unwrap_or(rest).trim();
        if !song_id.is_empty() && song_id.chars().all(|c| c.is_ascii_digit()) {
            let api_url = format!(
                "https://music.163.com/api/song/lyric?id={}&lv=1&kv=1&tv=-1",
                song_id
            );
            if let Ok(output) = std::process::Command::new("curl")
                .args([
                    "-s",
                    "-L",
                    "--max-time",
                    "4",
                    "-H",
                    "Referer: https://music.163.com/",
                    "-H",
                    "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
                    &api_url,
                ])
                .output()
            {
                if output.status.success() {
                    if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                        if let Some(lrc) = val
                            .get("lrc")
                            .and_then(|l| l.get("lyric"))
                            .and_then(|s| s.as_str())
                        {
                            let trimmed = lrc.trim();
                            if !trimmed.is_empty() {
                                return trimmed.to_string();
                            }
                        }
                    }
                }
            }
        }
    } else if let Some(rest) = uri.strip_prefix("qq://") {
        let song_mid = rest.strip_prefix("track/").unwrap_or(rest).trim();
        if !song_mid.is_empty() {
            let api_url = format!(
                "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid={}&format=json&nobase64=1",
                song_mid
            );
            if let Ok(output) = std::process::Command::new("curl")
                .args([
                    "-s",
                    "-L",
                    "--max-time",
                    "4",
                    "-H",
                    "Referer: https://y.qq.com/",
                    "-H",
                    "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
                    &api_url,
                ])
                .output()
            {
                if output.status.success() {
                    if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                        if let Some(lrc) = val.get("lyric").and_then(|s| s.as_str()) {
                            let trimmed = lrc
                                .replace("&#58;", ":")
                                .replace("&#46;", ".")
                                .replace("&#10;", "\n")
                                .replace("&#13;", "")
                                .replace("&#32;", " ")
                                .replace("&#45;", "-")
                                .replace("&#40;", "(")
                                .replace("&#41;", ")")
                                .replace("&apos;", "'")
                                .replace("&quot;", "\"")
                                .replace("&amp;", "&");
                            if !trimmed.trim().is_empty() {
                                return trimmed;
                            }
                        }
                    }
                }
            }
        }
    } else if uri.starts_with("bilibili://") {
        return "[00:00.00] [Bilibili 视频音频流 — 该视频源暂无 LRC 同步歌词]\n".to_string();
    }

    // Standard fallback lyrics for test/mock URIs
    let lines = vec![
        LyricLine { timestamp_ms: 1000, text: "Oh-My-Mineral Synchronized Lyrics".to_string() },
        LyricLine { timestamp_ms: 12500, text: "Hello Oh-My-Mineral Lyrics".to_string() },
        LyricLine { timestamp_ms: 25000, text: "High-performance Pascal Host with Rust Streaming Plugin".to_string() },
        LyricLine { timestamp_ms: 83450, text: "Synchronized lyric text".to_string() },
    ];
    to_lrc_string(&lines)
}

/// Copies formatted lyrics into a caller-allocated C buffer.
///
/// Safety:
/// - `uri` must be a valid null-terminated C string.
/// - `out_buf` may be null only if `buf_len == 0` (for size query).
/// - `out_len` must be a valid pointer to receive the size.
pub unsafe fn copy_lyrics_to_caller_buffer(
    uri: *const c_char,
    out_buf: *mut c_char,
    buf_len: usize,
    out_len: *mut usize,
) -> i32 {
    if uri.is_null() || out_len.is_null() {
        return OMM_ERR_INVALID_PARAM;
    }

    let uri_str = match CStr::from_ptr(uri).to_str() {
        Ok(s) => s,
        Err(_) => return OMM_ERR_INVALID_PARAM,
    };

    let lyrics = get_lyrics_for_uri(uri_str);
    let needed = lyrics.len();

    *out_len = needed;

    if out_buf.is_null() {
        if buf_len == 0 {
            return OMM_ERR_BUFFER_TOO_SMALL;
        } else {
            return OMM_ERR_INVALID_PARAM;
        }
    }

    // Required capacity is needed + 1 byte for null terminator
    if buf_len < needed + 1 {
        return OMM_ERR_BUFFER_TOO_SMALL;
    }

    ptr::copy_nonoverlapping(lyrics.as_ptr() as *const c_char, out_buf, needed);
    *out_buf.add(needed) = 0; // Null terminator

    OMM_OK
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_parse_timestamp() {
        assert_eq!(format_lrc_timestamp(83450), "[01:23.45]");
        assert_eq!(parse_lrc_timestamp("[01:23.45]"), Some(83450));
    }

    #[test]
    fn test_caller_buffer_copy() {
        let mut buf = [0 as c_char; 256];
        let mut out_len = 0;
        let uri = std::ffi::CString::new("mineral://stream/test").unwrap();

        unsafe {
            // Buffer too small query
            let res = copy_lyrics_to_caller_buffer(uri.as_ptr(), buf.as_mut_ptr(), 5, &mut out_len);
            assert_eq!(res, OMM_ERR_BUFFER_TOO_SMALL);
            assert!(out_len > 0);

            // Buffer adequate
            let mut big_buf = vec![0 as c_char; out_len + 16];
            let res2 = copy_lyrics_to_caller_buffer(uri.as_ptr(), big_buf.as_mut_ptr(), big_buf.len(), &mut out_len);
            assert_eq!(res2, OMM_OK);

            let cstr = CStr::from_ptr(big_buf.as_ptr());
            let s = cstr.to_str().unwrap();
            assert!(s.contains("Hello Oh-My-Mineral Lyrics"));
        }
    }
}
