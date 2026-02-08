//! Block compression and decompression utilities.

use crate::header::Compression;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum BlockError {
    #[error("LZ4 compression error: {0}")]
    Lz4Compress(String),
    #[error("LZ4 decompression error: {0}")]
    Lz4Decompress(String),
    #[error("Zstd error: {0}")]
    Zstd(#[from] std::io::Error),
    #[error("block CRC mismatch: expected {expected:#010x}, got {actual:#010x}")]
    CrcMismatch { expected: u32, actual: u32 },
}

/// Compress a block of raw bytes.
pub fn compress_block(data: &[u8], codec: Compression) -> Result<Vec<u8>, BlockError> {
    match codec {
        Compression::None => Ok(data.to_vec()),
        Compression::Lz4 => Ok(lz4_flex::compress_prepend_size(data)),
        Compression::Zstd => {
            zstd::bulk::compress(data, 3).map_err(BlockError::Zstd)
        }
    }
}

/// Decompress a block of compressed bytes.
pub fn decompress_block(
    data: &[u8],
    codec: Compression,
    uncompressed_size: usize,
) -> Result<Vec<u8>, BlockError> {
    match codec {
        Compression::None => Ok(data.to_vec()),
        Compression::Lz4 => lz4_flex::decompress_size_prepended(data)
            .map_err(|e| BlockError::Lz4Decompress(e.to_string())),
        Compression::Zstd => {
            zstd::bulk::decompress(data, uncompressed_size).map_err(BlockError::Zstd)
        }
    }
}

/// Verify the CRC of uncompressed block data.
pub fn verify_block_crc(data: &[u8], expected_crc: u32) -> Result<(), BlockError> {
    let actual = crc32c::crc32c(data);
    if actual != expected_crc {
        return Err(BlockError::CrcMismatch {
            expected: expected_crc,
            actual,
        });
    }
    Ok(())
}

/// Serialize records into a flat block buffer.
/// Each record is [timestamp LE u64] [value bytes].
pub fn serialize_block(records: &[(u64, &[u8])], record_value_size: u32) -> Vec<u8> {
    let record_size = 8 + record_value_size as usize;
    let mut buf = Vec::with_capacity(records.len() * record_size);
    for (ts, value) in records {
        buf.extend_from_slice(&ts.to_le_bytes());
        buf.extend_from_slice(value);
        // Pad if value is shorter than record_value_size (shouldn't happen with correct usage)
        let pad = record_value_size as usize - value.len();
        if pad > 0 {
            buf.extend(std::iter::repeat(0u8).take(pad));
        }
    }
    buf
}

/// Parse records from an uncompressed block buffer.
/// Returns (timestamp, value_start_offset) pairs within the buffer.
pub fn parse_block_timestamps(data: &[u8], record_value_size: u32) -> Vec<u64> {
    let record_size = 8 + record_value_size as usize;
    let count = data.len() / record_size;
    let mut timestamps = Vec::with_capacity(count);
    for i in 0..count {
        let offset = i * record_size;
        let ts = u64::from_le_bytes(data[offset..offset + 8].try_into().unwrap());
        timestamps.push(ts);
    }
    timestamps
}

/// Extract a single record from an uncompressed block buffer.
pub fn extract_record(data: &[u8], index: usize, record_value_size: u32) -> (u64, &[u8]) {
    let record_size = 8 + record_value_size as usize;
    let offset = index * record_size;
    let ts = u64::from_le_bytes(data[offset..offset + 8].try_into().unwrap());
    let value = &data[offset + 8..offset + record_size];
    (ts, value)
}
