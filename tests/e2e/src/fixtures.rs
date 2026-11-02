//! Synthetic test audio generators and fixtures.
//!
//! Generates valid, compliant FLAC, MP3, WAV, and PCM byte sequences
//! so tests can execute without requiring external media files.

use std::f32::consts::PI;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use tempfile::NamedTempFile;

/// Embedded valid FLAC fixture bytes from project assets.
pub const BASE_FLAC_BYTES: &[u8] = include_bytes!("../../../vendor/mineral-server/src/tagging/fixtures/tone.flac");

/// Embedded valid MP3 fixture bytes from project assets.
pub const BASE_MP3_BYTES: &[u8] = include_bytes!("../../../vendor/mineral-server/src/tagging/fixtures/tone.mp3");

/// Generates a valid RIFF/WAVE PCM audio byte buffer.
///
/// # Arguments
/// * `duration_ms` - Length of generated audio in milliseconds
/// * `sample_rate` - e.g. 44100 or 48000 Hz
/// * `channels` - 1 for mono, 2 for stereo
/// * `freq_hz` - Sine wave pitch frequency in Hz (e.g. 440.0 for A4)
pub fn generate_wav(duration_ms: u32, sample_rate: u32, channels: u16, freq_hz: f32) -> Vec<u8> {
    let total_samples = ((duration_ms as u64 * sample_rate as u64) / 1000) as usize;
    let bits_per_sample: u16 = 16;
    let block_align = channels * (bits_per_sample / 8);
    let byte_rate = sample_rate * block_align as u32;
    let data_bytes = (total_samples * block_align as usize) as u32;
    let riff_chunk_size = 36 + data_bytes;

    let mut buf = Vec::with_capacity(44 + data_bytes as usize);

    // RIFF Header
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&riff_chunk_size.to_le_bytes());
    buf.extend_from_slice(b"WAVE");

    // "fmt " Subchunk
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes()); // Subchunk1Size for PCM
    buf.extend_from_slice(&1u16.to_le_bytes());  // AudioFormat: 1 = PCM
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&bits_per_sample.to_le_bytes());

    // "data" Subchunk
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_bytes.to_le_bytes());

    // Generate interleaved 16-bit signed PCM samples (sine wave)
    let amplitude = 0.8 * (i16::MAX as f32);
    for i in 0..total_samples {
        let t = i as f32 / sample_rate as f32;
        let sample_val = (amplitude * (2.0 * PI * freq_hz * t).sin()) as i16;
        for _ in 0..channels {
            buf.extend_from_slice(&sample_val.to_le_bytes());
        }
    }

    buf
}

/// Generates raw 16-bit signed little-endian PCM sample bytes.
pub fn generate_pcm(duration_ms: u32, sample_rate: u32, channels: u16, freq_hz: f32) -> Vec<u8> {
    let total_samples = ((duration_ms as u64 * sample_rate as u64) / 1000) as usize;
    let block_align = channels * 2;
    let mut buf = Vec::with_capacity(total_samples * block_align as usize);

    let amplitude = 0.8 * (i16::MAX as f32);
    for i in 0..total_samples {
        let t = i as f32 / sample_rate as f32;
        let sample_val = (amplitude * (2.0 * PI * freq_hz * t).sin()) as i16;
        for _ in 0..channels {
            buf.extend_from_slice(&sample_val.to_le_bytes());
        }
    }

    buf
}

/// Generates a valid FLAC audio stream containing Vorbis comment metadata.
///
/// Injects custom TITLE, ARTIST, and ALBUM metadata blocks.
pub fn generate_flac(duration_ms: u32, title: &str, artist: &str, album: &str) -> Vec<u8> {
    let _ = duration_ms;
    // We base our FLAC generation on the known valid stream structure
    // and synthesize a custom Vorbis comment metadata block.
    let mut out = Vec::new();
    // FLAC Magic
    out.extend_from_slice(b"fLaC");

    // METADATA_BLOCK_HEADER + STREAMINFO (Block Type 0, 34 bytes, is_last = false)
    let is_last = 0x00u8; // false
    let block_type = 0u8; // STREAMINFO
    out.push(is_last | (block_type & 0x7F));
    out.extend_from_slice(&34u32.to_be_bytes()[1..4]); // 24-bit length: 34

    // STREAMINFO Payload (34 bytes):
    // min_blocksize: 4096, max_blocksize: 4096
    out.extend_from_slice(&4096u16.to_be_bytes());
    out.extend_from_slice(&4096u16.to_be_bytes());
    // min_framesize: 14, max_framesize: 14 (24 bits each)
    out.extend_from_slice(&[0, 0, 14]);
    out.extend_from_slice(&[0, 0, 14]);
    // sample_rate (20 bits): 44100 (0x0AC44)
    // channels (3 bits): 2 - 1 = 1
    // bits_per_sample (5 bits): 16 - 1 = 15
    // total_samples (36 bits): 44100 * (duration_ms / 1000)
    let sr: u32 = 44100;
    let ch: u32 = 1; // 2 channels
    let bps: u32 = 15; // 16 bits
    let total_samples: u64 = (sr as u64 * duration_ms as u64) / 1000;
    
    // Pack 20-bit SR + 3-bit CH + 5-bit BPS + 4 high bits of total_samples
    let b1 = (sr >> 12) as u8;
    let b2 = (sr >> 4) as u8;
    let b3 = (((sr & 0x0F) << 4) | (ch << 1) | (bps >> 4)) as u8;
    let b4 = (((bps & 0x0F) << 4) as u8) | (((total_samples >> 32) as u8) & 0x0F);
    out.extend_from_slice(&[b1, b2, b3, b4]);
    out.extend_from_slice(&(total_samples as u32).to_be_bytes());
    // MD5 Signature: 16 zero bytes
    out.extend_from_slice(&[0u8; 16]);

    // METADATA_BLOCK_HEADER + VORBIS_COMMENT (Block Type 4, is_last = true)
    let is_last_comment = 0x80u8; // true (last metadata block before audio)
    let comment_type = 4u8; // VORBIS_COMMENT
    
    let mut comment_payload = Vec::new();
    let vendor = "Oh-My-Mineral Synthetic Test Audio";
    comment_payload.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    comment_payload.extend_from_slice(vendor.as_bytes());

    let comments = vec![
        format!("TITLE={}", title),
        format!("ARTIST={}", artist),
        format!("ALBUM={}", album),
    ];
    comment_payload.extend_from_slice(&(comments.len() as u32).to_le_bytes());
    for c in comments {
        comment_payload.extend_from_slice(&(c.len() as u32).to_le_bytes());
        comment_payload.extend_from_slice(c.as_bytes());
    }

    out.push(is_last_comment | (comment_type & 0x7F));
    let comment_len = comment_payload.len() as u32;
    out.extend_from_slice(&comment_len.to_be_bytes()[1..4]); // 24-bit length
    out.extend_from_slice(&comment_payload);

    // Append audio frames from valid base FLAC fixture to ensure decoder compatibility
    if BASE_FLAC_BYTES.len() > 42 {
        // Skip base header (4-byte magic + 38-byte STREAMINFO block) and append raw audio frames
        out.extend_from_slice(&BASE_FLAC_BYTES[42..]);
    } else {
        // Fallback minimal silent frame
        out.extend_from_slice(&[0xFF, 0xF8, 0x69, 0x02, 0x00, 0x00, 0x00]);
    }

    out
}

/// Generates a valid MP3 audio stream with ID3v2 tag and MPEG-1 Layer 3 frames.
pub fn generate_mp3(duration_ms: u32, title: &str, artist: &str) -> Vec<u8> {
    let _ = duration_ms;
    let mut out = Vec::new();

    // Build ID3v2.3 tag
    let mut tag_body = Vec::new();
    // TIT2 (Title) frame
    let tit2_body = format!("\0{}", title);
    tag_body.extend_from_slice(b"TIT2");
    tag_body.extend_from_slice(&(tit2_body.len() as u32).to_be_bytes());
    tag_body.extend_from_slice(&[0, 0]); // flags
    tag_body.extend_from_slice(tit2_body.as_bytes());

    // TPE1 (Artist) frame
    let tpe1_body = format!("\0{}", artist);
    tag_body.extend_from_slice(b"TPE1");
    tag_body.extend_from_slice(&(tpe1_body.len() as u32).to_be_bytes());
    tag_body.extend_from_slice(&[0, 0]); // flags
    tag_body.extend_from_slice(tpe1_body.as_bytes());

    // ID3v2 Header (10 bytes)
    out.extend_from_slice(b"ID3\x03\x00\x00"); // ID3v2.3.0, no flags
    // Encode tag size as synchsafe integer (7 bits per byte)
    let tag_size = tag_body.len() as u32;
    let s0 = ((tag_size >> 21) & 0x7F) as u8;
    let s1 = ((tag_size >> 14) & 0x7F) as u8;
    let s2 = ((tag_size >> 7) & 0x7F) as u8;
    let s3 = (tag_size & 0x7F) as u8;
    out.extend_from_slice(&[s0, s1, s2, s3]);
    out.extend_from_slice(&tag_body);

    // Append valid MP3 audio frames from base fixture
    out.extend_from_slice(BASE_MP3_BYTES);

    out
}

/// Kinds of synthetic corrupted audio data for negative and boundary testing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CorruptKind {
    /// 0-byte completely empty file
    Empty,
    /// Truncated header (e.g. only 4 bytes of WAV or FLAC)
    TruncatedHeader,
    /// Invalid magic bytes ("XXXX")
    BadMagicBytes,
    /// Flipped CRC / checksum bits
    InvalidChecksum,
    /// Arbitrary pseudo-random noise bytes
    RandomNoise,
    /// Header declaring huge data size but payload missing
    OversizedHeader,
    /// Frame sync word damaged
    CorruptSyncWord,
}

/// Generates corrupted or boundary audio byte buffers.
pub fn generate_corrupt_audio(kind: CorruptKind) -> Vec<u8> {
    match kind {
        CorruptKind::Empty => Vec::new(),
        CorruptKind::TruncatedHeader => b"RIFF\x20\x00\x00".to_vec(),
        CorruptKind::BadMagicBytes => b"CORRUPT_AUDIO_MAGIC_BYTES_1234567890".to_vec(),
        CorruptKind::InvalidChecksum => {
            let mut flac = generate_flac(100, "Corrupt", "Artist", "Album");
            if flac.len() > 20 {
                // Invalidate MD5 signature or streaminfo bits
                flac[15] ^= 0xFF;
                flac[16] ^= 0xFF;
            }
            flac
        }
        CorruptKind::RandomNoise => {
            let mut noise = Vec::with_capacity(4096);
            let mut state: u64 = 0xDEADBEEFCAFEBABE;
            for _ in 0..4096 {
                // Simple 64-bit LCG
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                noise.push((state >> 32) as u8);
            }
            noise
        }
        CorruptKind::OversizedHeader => {
            let mut buf = Vec::new();
            buf.extend_from_slice(b"RIFF");
            buf.extend_from_slice(&0x7FFFFFFF_u32.to_le_bytes()); // Claims 2 GB
            buf.extend_from_slice(b"WAVEfmt ");
            buf.extend_from_slice(&16u32.to_le_bytes());
            buf.extend_from_slice(&1u16.to_le_bytes());
            buf.extend_from_slice(&2u16.to_le_bytes());
            buf.extend_from_slice(&44100u32.to_le_bytes());
            buf.extend_from_slice(&(44100u32 * 4).to_le_bytes());
            buf.extend_from_slice(&4u16.to_le_bytes());
            buf.extend_from_slice(&16u16.to_le_bytes());
            buf.extend_from_slice(b"data");
            buf.extend_from_slice(&0x7FFFF000_u32.to_le_bytes());
            buf.extend_from_slice(&[0u8; 32]); // Truncated: only 32 bytes provided
            buf
        }
        CorruptKind::CorruptSyncWord => {
            let mut mp3 = generate_mp3(100, "BadSync", "Artist");
            // Find MPEG sync word 0xFF 0xFB and corrupt it
            for i in 0..mp3.len().saturating_sub(1) {
                if mp3[i] == 0xFF && (mp3[i + 1] & 0xE0) == 0xE0 {
                    mp3[i] = 0x00;
                    mp3[i + 1] = 0x00;
                    break;
                }
            }
            mp3
        }
    }
}

/// Helper to persist bytes to a temporary file with a specific extension (e.g. "flac", "wav").
pub fn write_temp_audio_file(data: &[u8], extension: &str) -> (NamedTempFile, PathBuf) {
    let temp_file = tempfile::Builder::new()
        .prefix("omm_test_")
        .suffix(&format!(".{}", extension))
        .tempfile()
        .expect("Failed to create temporary audio file");

    let path = temp_file.path().to_path_buf();
    let mut file = File::create(&path).expect("Failed to open temp audio file for writing");
    file.write_all(data).expect("Failed to write test audio data");
    file.flush().expect("Failed to flush test audio data");

    (temp_file, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_wav_validity() {
        let wav = generate_wav(500, 44100, 2, 440.0);
        assert!(wav.len() > 44);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[12..16], b"fmt ");
        assert_eq!(&wav[36..40], b"data");
    }

    #[test]
    fn test_generate_pcm_validity() {
        let pcm = generate_pcm(250, 44100, 2, 440.0);
        let expected_samples = (250 * 44100) / 1000;
        let expected_bytes = expected_samples * 4; // 16-bit stereo = 4 bytes/sample
        assert_eq!(pcm.len(), expected_bytes as usize);
    }

    #[test]
    fn test_generate_flac_validity() {
        let flac = generate_flac(200, "Song A", "Artist B", "Album C");
        assert!(flac.len() > 42);
        assert_eq!(&flac[0..4], b"fLaC");
    }

    #[test]
    fn test_generate_mp3_validity() {
        let mp3 = generate_mp3(200, "Song X", "Artist Y");
        assert!(mp3.len() > 10);
        assert_eq!(&mp3[0..3], b"ID3");
    }

    #[test]
    fn test_corrupt_kinds() {
        assert!(generate_corrupt_audio(CorruptKind::Empty).is_empty());
        assert!(!generate_corrupt_audio(CorruptKind::TruncatedHeader).is_empty());
        assert!(!generate_corrupt_audio(CorruptKind::RandomNoise).is_empty());
    }
}
