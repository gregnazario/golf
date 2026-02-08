//! Header encoding and decoding for the golf file format.

use crate::{FIXED_HEADER_SIZE, FORMAT_VERSION, HEADER_MAGIC};
use std::io::{self, Read, Write};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum HeaderError {
    #[error("invalid magic bytes")]
    InvalidMagic,
    #[error("unsupported version: {0}")]
    UnsupportedVersion(u16),
    #[error("invalid header CRC: expected {expected:#010x}, got {actual:#010x}")]
    InvalidCrc { expected: u32, actual: u32 },
    #[error("invalid timestamp resolution: {0}")]
    InvalidTimestampResolution(u8),
    #[error("invalid compression codec: {0}")]
    InvalidCompression(u8),
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
}

/// Timestamp resolution stored in the header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TimestampResolution {
    Nanoseconds = 0,
    Microseconds = 1,
    Milliseconds = 2,
}

impl TimestampResolution {
    pub fn from_u8(v: u8) -> Result<Self, HeaderError> {
        match v {
            0 => Ok(Self::Nanoseconds),
            1 => Ok(Self::Microseconds),
            2 => Ok(Self::Milliseconds),
            _ => Err(HeaderError::InvalidTimestampResolution(v)),
        }
    }
}

/// Compression codec stored in the header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Compression {
    None = 0,
    Lz4 = 1,
    Zstd = 2,
}

impl Compression {
    pub fn from_u8(v: u8) -> Result<Self, HeaderError> {
        match v {
            0 => Ok(Self::None),
            1 => Ok(Self::Lz4),
            2 => Ok(Self::Zstd),
            _ => Err(HeaderError::InvalidCompression(v)),
        }
    }
}

/// Parsed fixed header of a golf file.
#[derive(Debug, Clone)]
pub struct Header {
    pub version: u16,
    pub flags: u16,
    pub record_value_size: u32,
    pub ts_resolution: TimestampResolution,
    pub compression: Compression,
    pub block_capacity: u32,
    pub min_timestamp: u64,
    pub max_timestamp: u64,
    pub record_count: u64,
    pub metadata_length: u32,
}

/// A metadata key-value pair.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MetadataEntry {
    pub key: String,
    pub value: String,
}

impl Header {
    /// Encode the fixed header into exactly 64 bytes.
    pub fn encode(&self) -> [u8; FIXED_HEADER_SIZE] {
        let mut buf = [0u8; FIXED_HEADER_SIZE];
        buf[0..4].copy_from_slice(&HEADER_MAGIC);
        buf[4..6].copy_from_slice(&self.version.to_le_bytes());
        buf[6..8].copy_from_slice(&self.flags.to_le_bytes());
        buf[8..12].copy_from_slice(&self.record_value_size.to_le_bytes());
        buf[12] = self.ts_resolution as u8;
        buf[13] = self.compression as u8;
        buf[14..18].copy_from_slice(&self.block_capacity.to_le_bytes());
        // 18..28 reserved (zeros)
        buf[28..36].copy_from_slice(&self.min_timestamp.to_le_bytes());
        buf[36..44].copy_from_slice(&self.max_timestamp.to_le_bytes());
        buf[44..52].copy_from_slice(&self.record_count.to_le_bytes());
        buf[52..56].copy_from_slice(&self.metadata_length.to_le_bytes());
        let crc = crc32c::crc32c(&buf[0..56]);
        buf[56..60].copy_from_slice(&crc.to_le_bytes());
        // 60..64 padding (zeros)
        buf
    }

    /// Decode a fixed header from exactly 64 bytes.
    pub fn decode(buf: &[u8; FIXED_HEADER_SIZE]) -> Result<Self, HeaderError> {
        if buf[0..4] != HEADER_MAGIC {
            return Err(HeaderError::InvalidMagic);
        }
        let version = u16::from_le_bytes([buf[4], buf[5]]);
        if version != FORMAT_VERSION {
            return Err(HeaderError::UnsupportedVersion(version));
        }
        let flags = u16::from_le_bytes([buf[6], buf[7]]);
        let record_value_size = u32::from_le_bytes(buf[8..12].try_into().unwrap());
        let ts_resolution = TimestampResolution::from_u8(buf[12])?;
        let compression = Compression::from_u8(buf[13])?;
        let block_capacity = u32::from_le_bytes(buf[14..18].try_into().unwrap());
        let min_timestamp = u64::from_le_bytes(buf[28..36].try_into().unwrap());
        let max_timestamp = u64::from_le_bytes(buf[36..44].try_into().unwrap());
        let record_count = u64::from_le_bytes(buf[44..52].try_into().unwrap());
        let metadata_length = u32::from_le_bytes(buf[52..56].try_into().unwrap());

        let stored_crc = u32::from_le_bytes(buf[56..60].try_into().unwrap());
        let computed_crc = crc32c::crc32c(&buf[0..56]);
        if stored_crc != computed_crc {
            return Err(HeaderError::InvalidCrc {
                expected: computed_crc,
                actual: stored_crc,
            });
        }

        Ok(Header {
            version,
            flags,
            record_value_size,
            ts_resolution,
            compression,
            block_capacity,
            min_timestamp,
            max_timestamp,
            record_count,
            metadata_length,
        })
    }
}

/// Encode metadata entries into bytes.
pub fn encode_metadata(entries: &[MetadataEntry]) -> Vec<u8> {
    let mut buf = Vec::new();
    for entry in entries {
        let kb = entry.key.as_bytes();
        let vb = entry.value.as_bytes();
        buf.extend_from_slice(&(kb.len() as u16).to_le_bytes());
        buf.extend_from_slice(kb);
        buf.extend_from_slice(&(vb.len() as u16).to_le_bytes());
        buf.extend_from_slice(vb);
    }
    buf
}

/// Decode metadata entries from bytes.
pub fn decode_metadata(mut data: &[u8]) -> Result<Vec<MetadataEntry>, HeaderError> {
    let mut entries = Vec::new();
    while !data.is_empty() {
        if data.len() < 2 {
            return Err(HeaderError::Io(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "truncated metadata key length",
            )));
        }
        let key_len = u16::from_le_bytes([data[0], data[1]]) as usize;
        data = &data[2..];
        if data.len() < key_len {
            return Err(HeaderError::Io(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "truncated metadata key",
            )));
        }
        let key = String::from_utf8_lossy(&data[..key_len]).into_owned();
        data = &data[key_len..];

        if data.len() < 2 {
            return Err(HeaderError::Io(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "truncated metadata value length",
            )));
        }
        let value_len = u16::from_le_bytes([data[0], data[1]]) as usize;
        data = &data[2..];
        if data.len() < value_len {
            return Err(HeaderError::Io(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "truncated metadata value",
            )));
        }
        let value = String::from_utf8_lossy(&data[..value_len]).into_owned();
        data = &data[value_len..];

        entries.push(MetadataEntry { key, value });
    }
    Ok(entries)
}

/// Write the full header (fixed + metadata) to a writer.
pub fn write_header<W: Write>(
    w: &mut W,
    header: &Header,
    metadata: &[MetadataEntry],
) -> io::Result<()> {
    let encoded = header.encode();
    w.write_all(&encoded)?;
    if header.metadata_length > 0 {
        let meta_bytes = encode_metadata(metadata);
        debug_assert_eq!(meta_bytes.len(), header.metadata_length as usize);
        w.write_all(&meta_bytes)?;
    }
    Ok(())
}

/// Read the full header (fixed + metadata) from a reader.
pub fn read_header<R: Read>(r: &mut R) -> Result<(Header, Vec<MetadataEntry>), HeaderError> {
    let mut buf = [0u8; FIXED_HEADER_SIZE];
    r.read_exact(&mut buf)?;
    let header = Header::decode(&buf)?;
    let metadata = if header.metadata_length > 0 {
        let mut meta_buf = vec![0u8; header.metadata_length as usize];
        r.read_exact(&mut meta_buf)?;
        decode_metadata(&meta_buf)?
    } else {
        Vec::new()
    };
    Ok((header, metadata))
}
