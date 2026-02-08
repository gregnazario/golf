//! GolfReader: read-only access to .golf files with range query support.

use crate::block::{decompress_block, extract_record, verify_block_crc};
use crate::header::{decode_metadata, Compression, Header, MetadataEntry};
use crate::index::{
    decode_index, find_first_block, find_last_block, verify_index_crc, BlockDescriptor,
};
use crate::{Record, BLOCK_DESCRIPTOR_SIZE, FIXED_HEADER_SIZE, FOOTER_MAGIC, FOOTER_SIZE};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ReaderError {
    #[error("header error: {0}")]
    Header(#[from] crate::header::HeaderError),
    #[error("index error: {0}")]
    Index(#[from] crate::index::IndexError),
    #[error("block error: {0}")]
    Block(#[from] crate::block::BlockError),
    #[error("invalid footer magic")]
    InvalidFooterMagic,
    #[error("footer CRC mismatch: expected {expected:#010x}, got {actual:#010x}")]
    FooterCrcMismatch { expected: u32, actual: u32 },
    #[error("file too small: {0} bytes")]
    FileTooSmall(u64),
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
}

/// Parsed footer of a golf file.
#[derive(Debug, Clone)]
struct Footer {
    index_offset: u64,
    block_count: u64,
    index_crc: u32,
}

/// A reader for .golf files using standard read() + seek() I/O.
pub struct GolfReader<R: Read + Seek> {
    inner: R,
    header: Header,
    metadata: Vec<MetadataEntry>,
    index: Vec<BlockDescriptor>,
}

/// A reader for .golf files using memory-mapped I/O.
pub struct MmapGolfReader {
    #[allow(dead_code)]
    mmap: memmap2::Mmap,
    data: *const u8,
    #[allow(dead_code)]
    len: usize,
    header: Header,
    metadata: Vec<MetadataEntry>,
    index: Vec<BlockDescriptor>,
}

// Safety: The Mmap is read-only and the data pointer is derived from it.
unsafe impl Send for MmapGolfReader {}
unsafe impl Sync for MmapGolfReader {}

// ── Footer parsing (shared) ──

fn parse_footer(buf: &[u8; FOOTER_SIZE]) -> Result<Footer, ReaderError> {
    // Validate footer magic at offset 20..24
    if buf[20..24] != FOOTER_MAGIC {
        return Err(ReaderError::InvalidFooterMagic);
    }
    // Validate footer CRC (covers bytes 0..24)
    let stored_crc = u32::from_le_bytes(buf[24..28].try_into().unwrap());
    let computed_crc = crc32c::crc32c(&buf[0..24]);
    if stored_crc != computed_crc {
        return Err(ReaderError::FooterCrcMismatch {
            expected: computed_crc,
            actual: stored_crc,
        });
    }
    Ok(Footer {
        index_offset: u64::from_le_bytes(buf[0..8].try_into().unwrap()),
        block_count: u64::from_le_bytes(buf[8..16].try_into().unwrap()),
        index_crc: u32::from_le_bytes(buf[16..20].try_into().unwrap()),
    })
}

// ── Range query logic (shared) ──

fn collect_range_from_blocks(
    descriptors: &[BlockDescriptor],
    compression: Compression,
    record_value_size: u32,
    start_ts: u64,
    end_ts: u64,
    read_block: &mut dyn FnMut(&BlockDescriptor) -> Result<Vec<u8>, ReaderError>,
) -> Result<Vec<Record>, ReaderError> {
    let first_idx = match find_first_block(descriptors, start_ts) {
        Some(i) => i,
        None => return Ok(Vec::new()),
    };
    let last_idx = match find_last_block(descriptors, end_ts) {
        Some(i) => i,
        None => return Ok(Vec::new()),
    };
    if first_idx > last_idx {
        return Ok(Vec::new());
    }

    let record_size = 8 + record_value_size as usize;
    let mut results = Vec::new();

    for block_idx in first_idx..=last_idx {
        let desc = &descriptors[block_idx];

        // Read compressed block data
        let compressed = read_block(desc)?;

        // Decompress
        let raw = decompress_block(&compressed, compression, desc.uncompressed_size as usize)?;

        // Verify CRC
        verify_block_crc(&raw, desc.block_crc)?;

        let count = desc.record_count as usize;

        // Determine record range within this block
        let (rec_start, rec_end) = if block_idx == first_idx || block_idx == last_idx {
            // Binary search for boundaries
            let s = if block_idx == first_idx {
                // Find first record where ts >= start_ts
                binary_search_first(&raw, record_size, count, start_ts)
            } else {
                0
            };
            let e = if block_idx == last_idx {
                // Find last record where ts <= end_ts
                binary_search_last(&raw, record_size, count, end_ts)
            } else {
                count.saturating_sub(1)
            };
            (s, e)
        } else {
            // Middle block: all records are in range
            (0, count - 1)
        };

        if rec_start <= rec_end && rec_end < count {
            for i in rec_start..=rec_end {
                let (ts, value) = extract_record(&raw, i, record_value_size);
                if ts >= start_ts && ts <= end_ts {
                    results.push(Record {
                        timestamp: ts,
                        value: value.to_vec(),
                    });
                }
            }
        }
    }

    Ok(results)
}

/// Binary search for the first record index where timestamp >= target.
fn binary_search_first(data: &[u8], record_size: usize, count: usize, target: u64) -> usize {
    let mut lo = 0;
    let mut hi = count;
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let ts = u64::from_le_bytes(
            data[mid * record_size..mid * record_size + 8]
                .try_into()
                .unwrap(),
        );
        if ts < target {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}

/// Binary search for the last record index where timestamp <= target.
fn binary_search_last(data: &[u8], record_size: usize, count: usize, target: u64) -> usize {
    let mut lo = 0;
    let mut hi = count;
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let ts = u64::from_le_bytes(
            data[mid * record_size..mid * record_size + 8]
                .try_into()
                .unwrap(),
        );
        if ts <= target {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo.saturating_sub(1)
}

// ── GolfReader (read + seek) ──

impl<R: Read + Seek> GolfReader<R> {
    /// Open a golf file from a reader.
    pub fn open(mut inner: R) -> Result<Self, ReaderError> {
        // Get file size
        let file_size = inner.seek(SeekFrom::End(0))?;
        if file_size < (FIXED_HEADER_SIZE + FOOTER_SIZE) as u64 {
            return Err(ReaderError::FileTooSmall(file_size));
        }

        // Read footer
        inner.seek(SeekFrom::End(-(FOOTER_SIZE as i64)))?;
        let mut footer_buf = [0u8; FOOTER_SIZE];
        inner.read_exact(&mut footer_buf)?;
        let footer = parse_footer(&footer_buf)?;

        // Read block index
        let index_size = footer.block_count as usize * BLOCK_DESCRIPTOR_SIZE;
        inner.seek(SeekFrom::Start(footer.index_offset))?;
        let mut index_buf = vec![0u8; index_size];
        inner.read_exact(&mut index_buf)?;
        verify_index_crc(&index_buf, footer.index_crc)?;
        let index = decode_index(&index_buf)?;

        // Read header
        inner.seek(SeekFrom::Start(0))?;
        let mut header_buf = [0u8; FIXED_HEADER_SIZE];
        inner.read_exact(&mut header_buf)?;
        let header = Header::decode(&header_buf)?;

        // Read metadata
        let metadata = if header.metadata_length > 0 {
            let mut meta_buf = vec![0u8; header.metadata_length as usize];
            inner.read_exact(&mut meta_buf)?;
            decode_metadata(&meta_buf)?
        } else {
            Vec::new()
        };

        Ok(GolfReader {
            inner,
            header,
            metadata,
            index,
        })
    }

    /// Return the file header.
    pub fn header(&self) -> &Header {
        &self.header
    }

    /// Return the file metadata.
    pub fn metadata(&self) -> &[MetadataEntry] {
        &self.metadata
    }

    /// Return the block index.
    pub fn index(&self) -> &[BlockDescriptor] {
        &self.index
    }

    /// Query records in the inclusive timestamp range [start_ts, end_ts].
    pub fn query(&mut self, start_ts: u64, end_ts: u64) -> Result<Vec<Record>, ReaderError> {
        let compression = self.header.compression;
        let record_value_size = self.header.record_value_size;
        let inner = &mut self.inner;

        collect_range_from_blocks(
            &self.index,
            compression,
            record_value_size,
            start_ts,
            end_ts,
            &mut |desc: &BlockDescriptor| {
                inner.seek(SeekFrom::Start(desc.block_offset))?;
                let mut buf = vec![0u8; desc.compressed_size as usize];
                inner.read_exact(&mut buf)?;
                Ok(buf)
            },
        )
    }

    /// Return total record count.
    pub fn record_count(&self) -> u64 {
        self.header.record_count
    }

    /// Return the timestamp range (min, max).
    pub fn timestamp_range(&self) -> (u64, u64) {
        (self.header.min_timestamp, self.header.max_timestamp)
    }
}

impl GolfReader<File> {
    /// Open a golf file from a filesystem path.
    pub fn open_path(path: impl AsRef<std::path::Path>) -> Result<Self, ReaderError> {
        let file = File::open(path)?;
        Self::open(file)
    }
}

// ── MmapGolfReader ──

impl MmapGolfReader {
    /// Open a golf file using memory-mapped I/O.
    pub fn open(file: &File) -> Result<Self, ReaderError> {
        let mmap = unsafe { memmap2::Mmap::map(file)? };
        let len = mmap.len();
        let data = mmap.as_ptr();

        if len < FIXED_HEADER_SIZE + FOOTER_SIZE {
            return Err(ReaderError::FileTooSmall(len as u64));
        }

        // Parse footer (last 32 bytes)
        let footer_slice: &[u8; FOOTER_SIZE] =
            unsafe { &*(data.add(len - FOOTER_SIZE) as *const [u8; FOOTER_SIZE]) };
        let footer = parse_footer(footer_slice)?;

        // Parse block index
        let index_start = footer.index_offset as usize;
        let index_size = footer.block_count as usize * BLOCK_DESCRIPTOR_SIZE;
        let index_slice = unsafe { std::slice::from_raw_parts(data.add(index_start), index_size) };
        verify_index_crc(index_slice, footer.index_crc)?;
        let index = decode_index(index_slice)?;

        // Parse header
        let header_slice: &[u8; FIXED_HEADER_SIZE] =
            unsafe { &*(data as *const [u8; FIXED_HEADER_SIZE]) };
        let header = Header::decode(header_slice)?;

        // Parse metadata
        let metadata = if header.metadata_length > 0 {
            let meta_start = FIXED_HEADER_SIZE;
            let meta_slice = unsafe {
                std::slice::from_raw_parts(data.add(meta_start), header.metadata_length as usize)
            };
            decode_metadata(meta_slice)?
        } else {
            Vec::new()
        };

        Ok(MmapGolfReader {
            mmap,
            data,
            len,
            header,
            metadata,
            index,
        })
    }

    /// Open a golf file by path using memory-mapped I/O.
    pub fn open_path(path: impl AsRef<std::path::Path>) -> Result<Self, ReaderError> {
        let file = File::open(path)?;
        Self::open(&file)
    }

    /// Return the file header.
    pub fn header(&self) -> &Header {
        &self.header
    }

    /// Return the file metadata.
    pub fn metadata(&self) -> &[MetadataEntry] {
        &self.metadata
    }

    /// Return the block index.
    pub fn index(&self) -> &[BlockDescriptor] {
        &self.index
    }

    /// Query records in the inclusive timestamp range [start_ts, end_ts].
    pub fn query(&self, start_ts: u64, end_ts: u64) -> Result<Vec<Record>, ReaderError> {
        let data = self.data;

        collect_range_from_blocks(
            &self.index,
            self.header.compression,
            self.header.record_value_size,
            start_ts,
            end_ts,
            &mut |desc: &BlockDescriptor| {
                let slice = unsafe {
                    std::slice::from_raw_parts(
                        data.add(desc.block_offset as usize),
                        desc.compressed_size as usize,
                    )
                };
                Ok(slice.to_vec())
            },
        )
    }

    /// Return total record count.
    pub fn record_count(&self) -> u64 {
        self.header.record_count
    }

    /// Return the timestamp range (min, max).
    pub fn timestamp_range(&self) -> (u64, u64) {
        (self.header.min_timestamp, self.header.max_timestamp)
    }
}
