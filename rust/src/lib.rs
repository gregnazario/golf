//! Golf: Read-only indexed storage file format for time-series range queries.
//!
//! A `.golf` file is created by appending records and sealing the file, after
//! which it is immutable and optimized for range queries over timestamp keys.

pub mod block;
pub mod header;
pub mod index;
pub mod reader;
pub mod writer;

pub use header::{Compression, TimestampResolution};
pub use reader::GolfReader;
pub use writer::GolfWriter;

/// A single record: a timestamp and a fixed-size value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub timestamp: u64,
    pub value: Vec<u8>,
}

/// Magic bytes at the start of a golf file: "GOLF"
pub const HEADER_MAGIC: [u8; 4] = [0x47, 0x4F, 0x4C, 0x46];

/// Magic bytes in the footer: "FLOG" (GOLF reversed)
pub const FOOTER_MAGIC: [u8; 4] = [0x46, 0x4C, 0x4F, 0x47];

/// Size of the fixed header in bytes.
pub const FIXED_HEADER_SIZE: usize = 64;

/// Size of a block descriptor in the block index.
pub const BLOCK_DESCRIPTOR_SIZE: usize = 40;

/// Size of the footer in bytes.
pub const FOOTER_SIZE: usize = 32;

/// Format version.
pub const FORMAT_VERSION: u16 = 1;
