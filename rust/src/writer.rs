//! GolfWriter: append records, then seal into an immutable .golf file.

use crate::block::{compress_block, serialize_block};
use crate::header::{
    encode_metadata, write_header, Compression, Header, MetadataEntry, TimestampResolution,
};
use crate::index::{encode_index, BlockDescriptor};
use crate::{FOOTER_MAGIC, FORMAT_VERSION, FOOTER_SIZE};
use std::io::{self, BufWriter, Write};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum WriterError {
    #[error("record value size mismatch: expected {expected}, got {actual}")]
    ValueSizeMismatch { expected: u32, actual: usize },
    #[error("writer already sealed")]
    AlreadySealed,
    #[error("no records to seal")]
    EmptyFile,
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("block compression error: {0}")]
    Block(#[from] crate::block::BlockError),
}

/// Configuration for building a golf file.
#[derive(Debug, Clone)]
pub struct WriterConfig {
    pub record_value_size: u32,
    pub ts_resolution: TimestampResolution,
    pub compression: Compression,
    pub block_capacity: u32,
    pub metadata: Vec<MetadataEntry>,
}

impl Default for WriterConfig {
    fn default() -> Self {
        WriterConfig {
            record_value_size: 64,
            ts_resolution: TimestampResolution::Nanoseconds,
            compression: Compression::Lz4,
            block_capacity: 8192,
            metadata: Vec::new(),
        }
    }
}

/// A writer that accumulates records and seals them into a .golf file.
pub struct GolfWriter {
    config: WriterConfig,
    records: Vec<(u64, Vec<u8>)>,
    sealed: bool,
}

impl GolfWriter {
    /// Create a new writer with the given configuration.
    pub fn new(config: WriterConfig) -> Self {
        GolfWriter {
            config,
            records: Vec::new(),
            sealed: false,
        }
    }

    /// Append a record. The value must be exactly `record_value_size` bytes.
    pub fn append(&mut self, timestamp: u64, value: Vec<u8>) -> Result<(), WriterError> {
        if self.sealed {
            return Err(WriterError::AlreadySealed);
        }
        if value.len() != self.config.record_value_size as usize {
            return Err(WriterError::ValueSizeMismatch {
                expected: self.config.record_value_size,
                actual: value.len(),
            });
        }
        self.records.push((timestamp, value));
        Ok(())
    }

    /// Return the number of records appended so far.
    pub fn len(&self) -> usize {
        self.records.len()
    }

    /// Return whether the writer has no records.
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// Seal the writer and write the .golf file to the given writer.
    /// Consumes self.
    pub fn seal<W: Write>(mut self, dest: W) -> Result<(), WriterError> {
        if self.sealed {
            return Err(WriterError::AlreadySealed);
        }
        if self.records.is_empty() {
            return Err(WriterError::EmptyFile);
        }
        self.sealed = true;

        // Sort records by timestamp
        self.records.sort_by_key(|(ts, _)| *ts);

        let mut w = BufWriter::new(dest);
        let record_value_size = self.config.record_value_size;
        let block_capacity = self.config.block_capacity as usize;

        // Encode metadata
        let meta_bytes = encode_metadata(&self.config.metadata);

        // Compute min/max timestamps
        let min_ts = self.records.first().unwrap().0;
        let max_ts = self.records.last().unwrap().0;

        // Build header
        let header = Header {
            version: FORMAT_VERSION,
            flags: 0,
            record_value_size,
            ts_resolution: self.config.ts_resolution,
            compression: self.config.compression,
            block_capacity: self.config.block_capacity,
            min_timestamp: min_ts,
            max_timestamp: max_ts,
            record_count: self.records.len() as u64,
            metadata_length: meta_bytes.len() as u32,
        };

        // Write header
        write_header(&mut w, &header, &self.config.metadata)?;

        // Track current file offset
        let mut offset = 64u64 + meta_bytes.len() as u64;

        // Build and write blocks
        let mut descriptors = Vec::new();
        let chunks: Vec<_> = self.records.chunks(block_capacity).collect();
        for chunk in &chunks {
            // Build the raw record pairs as (u64, &[u8])
            let record_refs: Vec<(u64, &[u8])> =
                chunk.iter().map(|(ts, v)| (*ts, v.as_slice())).collect();

            // Serialize block
            let raw = serialize_block(&record_refs, record_value_size);
            let block_crc = crc32c::crc32c(&raw);
            let uncompressed_size = raw.len() as u32;

            // Compress
            let compressed = compress_block(&raw, self.config.compression)?;
            let compressed_size = compressed.len() as u32;

            // Record descriptor
            let min_block_ts = chunk.first().unwrap().0;
            let max_block_ts = chunk.last().unwrap().0;
            descriptors.push(BlockDescriptor {
                min_ts: min_block_ts,
                max_ts: max_block_ts,
                block_offset: offset,
                compressed_size,
                uncompressed_size,
                record_count: chunk.len() as u32,
                block_crc,
            });

            // Write block
            w.write_all(&compressed)?;
            offset += compressed_size as u64;
        }

        // Write block index
        let index_offset = offset;
        let index_bytes = encode_index(&descriptors);
        let index_crc = crc32c::crc32c(&index_bytes);
        w.write_all(&index_bytes)?;

        // Write footer
        let block_count = descriptors.len() as u64;
        let mut footer = [0u8; FOOTER_SIZE];
        footer[0..8].copy_from_slice(&index_offset.to_le_bytes());
        footer[8..16].copy_from_slice(&block_count.to_le_bytes());
        footer[16..20].copy_from_slice(&index_crc.to_le_bytes());
        footer[20..24].copy_from_slice(&FOOTER_MAGIC);
        let footer_crc = crc32c::crc32c(&footer[0..24]);
        footer[24..28].copy_from_slice(&footer_crc.to_le_bytes());
        // 28..32 padding (zeros)
        w.write_all(&footer)?;
        w.flush()?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_writer_value_size_mismatch() {
        let mut w = GolfWriter::new(WriterConfig {
            record_value_size: 8,
            ..Default::default()
        });
        let result = w.append(1, vec![0u8; 16]);
        assert!(result.is_err());
    }

    #[test]
    fn test_writer_seal_empty() {
        let w = GolfWriter::new(WriterConfig::default());
        let mut buf = Vec::new();
        let result = w.seal(&mut buf);
        assert!(result.is_err());
    }

    #[test]
    fn test_writer_basic_seal() {
        let mut w = GolfWriter::new(WriterConfig {
            record_value_size: 8,
            compression: Compression::None,
            block_capacity: 4,
            ..Default::default()
        });
        for i in 0..10u64 {
            w.append(i * 100, vec![i as u8; 8]).unwrap();
        }
        let mut buf = Vec::new();
        w.seal(&mut buf).unwrap();
        // Should have valid header magic
        assert_eq!(&buf[0..4], b"GOLF");
        // Should have valid footer magic
        let footer_start = buf.len() - FOOTER_SIZE;
        assert_eq!(&buf[footer_start + 20..footer_start + 24], b"FLOG");
    }
}
