//! Block index encoding and decoding.

use crate::BLOCK_DESCRIPTOR_SIZE;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum IndexError {
    #[error("block index CRC mismatch: expected {expected:#010x}, got {actual:#010x}")]
    CrcMismatch { expected: u32, actual: u32 },
    #[error("block index size mismatch: expected {expected} bytes, got {actual}")]
    SizeMismatch { expected: usize, actual: usize },
}

/// A single block descriptor from the block index.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockDescriptor {
    pub min_ts: u64,
    pub max_ts: u64,
    pub block_offset: u64,
    pub compressed_size: u32,
    pub uncompressed_size: u32,
    pub record_count: u32,
    pub block_crc: u32,
}

impl BlockDescriptor {
    /// Encode a descriptor to 40 bytes.
    pub fn encode(&self) -> [u8; BLOCK_DESCRIPTOR_SIZE] {
        let mut buf = [0u8; BLOCK_DESCRIPTOR_SIZE];
        buf[0..8].copy_from_slice(&self.min_ts.to_le_bytes());
        buf[8..16].copy_from_slice(&self.max_ts.to_le_bytes());
        buf[16..24].copy_from_slice(&self.block_offset.to_le_bytes());
        buf[24..28].copy_from_slice(&self.compressed_size.to_le_bytes());
        buf[28..32].copy_from_slice(&self.uncompressed_size.to_le_bytes());
        buf[32..36].copy_from_slice(&self.record_count.to_le_bytes());
        buf[36..40].copy_from_slice(&self.block_crc.to_le_bytes());
        buf
    }

    /// Decode a descriptor from 40 bytes.
    pub fn decode(buf: &[u8; BLOCK_DESCRIPTOR_SIZE]) -> Self {
        BlockDescriptor {
            min_ts: u64::from_le_bytes(buf[0..8].try_into().unwrap()),
            max_ts: u64::from_le_bytes(buf[8..16].try_into().unwrap()),
            block_offset: u64::from_le_bytes(buf[16..24].try_into().unwrap()),
            compressed_size: u32::from_le_bytes(buf[24..28].try_into().unwrap()),
            uncompressed_size: u32::from_le_bytes(buf[28..32].try_into().unwrap()),
            record_count: u32::from_le_bytes(buf[32..36].try_into().unwrap()),
            block_crc: u32::from_le_bytes(buf[36..40].try_into().unwrap()),
        }
    }
}

/// Encode an entire block index to bytes.
pub fn encode_index(descriptors: &[BlockDescriptor]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(descriptors.len() * BLOCK_DESCRIPTOR_SIZE);
    for desc in descriptors {
        buf.extend_from_slice(&desc.encode());
    }
    buf
}

/// Decode an entire block index from bytes.
pub fn decode_index(data: &[u8]) -> Result<Vec<BlockDescriptor>, IndexError> {
    if data.len() % BLOCK_DESCRIPTOR_SIZE != 0 {
        return Err(IndexError::SizeMismatch {
            expected: (data.len() / BLOCK_DESCRIPTOR_SIZE + 1) * BLOCK_DESCRIPTOR_SIZE,
            actual: data.len(),
        });
    }
    let count = data.len() / BLOCK_DESCRIPTOR_SIZE;
    let mut descriptors = Vec::with_capacity(count);
    for i in 0..count {
        let start = i * BLOCK_DESCRIPTOR_SIZE;
        let chunk: &[u8; BLOCK_DESCRIPTOR_SIZE] = data[start..start + BLOCK_DESCRIPTOR_SIZE]
            .try_into()
            .unwrap();
        descriptors.push(BlockDescriptor::decode(chunk));
    }
    Ok(descriptors)
}

/// Verify the CRC of the encoded block index.
pub fn verify_index_crc(data: &[u8], expected_crc: u32) -> Result<(), IndexError> {
    let actual = crc32c::crc32c(data);
    if actual != expected_crc {
        return Err(IndexError::CrcMismatch {
            expected: expected_crc,
            actual,
        });
    }
    Ok(())
}

/// Binary search for the first block whose max_ts >= target.
pub fn find_first_block(descriptors: &[BlockDescriptor], target: u64) -> Option<usize> {
    if descriptors.is_empty() {
        return None;
    }
    let mut lo = 0usize;
    let mut hi = descriptors.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if descriptors[mid].max_ts < target {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if lo < descriptors.len() {
        Some(lo)
    } else {
        None
    }
}

/// Binary search for the last block whose min_ts <= target.
pub fn find_last_block(descriptors: &[BlockDescriptor], target: u64) -> Option<usize> {
    if descriptors.is_empty() {
        return None;
    }
    let mut lo = 0usize;
    let mut hi = descriptors.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if descriptors[mid].min_ts <= target {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if lo == 0 {
        None
    } else {
        Some(lo - 1)
    }
}
