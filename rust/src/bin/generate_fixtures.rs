//! Generates cross-language test fixtures in the testdata/ directory.

use golf::header::{Compression, MetadataEntry, TimestampResolution};
use golf::writer::{GolfWriter, WriterConfig};
use std::fs::File;
use std::path::Path;

fn main() {
    let testdata = Path::new(env!("CARGO_MANIFEST_DIR")).join("../testdata");
    std::fs::create_dir_all(&testdata).unwrap();

    generate_small_none(&testdata);
    generate_lz4(&testdata);
    generate_zstd(&testdata);
    generate_with_metadata(&testdata);

    println!("Generated test fixtures in {:?}", testdata);
}

/// small.golf: 20 records, no compression, value_size=8, block_capacity=4
fn generate_small_none(dir: &Path) {
    let config = WriterConfig {
        record_value_size: 8,
        ts_resolution: TimestampResolution::Nanoseconds,
        compression: Compression::None,
        block_capacity: 4,
        metadata: vec![],
    };
    let mut w = GolfWriter::new(config);
    for i in 0u64..20 {
        // Value: 8 bytes, first byte = i, rest zero
        let mut val = vec![0u8; 8];
        val[0] = i as u8;
        w.append(i * 1000, val).unwrap();
    }
    let file = File::create(dir.join("small.golf")).unwrap();
    w.seal(file).unwrap();
    println!("  small.golf: 20 records, no compression");
}

/// compressed_lz4.golf: 100 records, LZ4, value_size=16, block_capacity=8
fn generate_lz4(dir: &Path) {
    let config = WriterConfig {
        record_value_size: 16,
        ts_resolution: TimestampResolution::Microseconds,
        compression: Compression::Lz4,
        block_capacity: 8,
        metadata: vec![],
    };
    let mut w = GolfWriter::new(config);
    for i in 0u64..100 {
        let mut val = vec![0u8; 16];
        val[0] = (i & 0xff) as u8;
        val[1] = ((i >> 8) & 0xff) as u8;
        w.append(i * 500, val).unwrap();
    }
    let file = File::create(dir.join("compressed_lz4.golf")).unwrap();
    w.seal(file).unwrap();
    println!("  compressed_lz4.golf: 100 records, LZ4");
}

/// compressed_zstd.golf: 100 records, Zstd, value_size=16, block_capacity=8
fn generate_zstd(dir: &Path) {
    let config = WriterConfig {
        record_value_size: 16,
        ts_resolution: TimestampResolution::Milliseconds,
        compression: Compression::Zstd,
        block_capacity: 8,
        metadata: vec![],
    };
    let mut w = GolfWriter::new(config);
    for i in 0u64..100 {
        let mut val = vec![0u8; 16];
        val[0] = (i & 0xff) as u8;
        val[1] = ((i >> 8) & 0xff) as u8;
        w.append(i * 500, val).unwrap();
    }
    let file = File::create(dir.join("compressed_zstd.golf")).unwrap();
    w.seal(file).unwrap();
    println!("  compressed_zstd.golf: 100 records, Zstd");
}

/// with_metadata.golf: 10 records, no compression, with metadata
fn generate_with_metadata(dir: &Path) {
    let config = WriterConfig {
        record_value_size: 8,
        ts_resolution: TimestampResolution::Nanoseconds,
        compression: Compression::None,
        block_capacity: 4,
        metadata: vec![
            MetadataEntry {
                key: "source".into(),
                value: "fixture-generator".into(),
            },
            MetadataEntry {
                key: "version".into(),
                value: "1.0.0".into(),
            },
        ],
    };
    let mut w = GolfWriter::new(config);
    for i in 0u64..10 {
        let mut val = vec![0u8; 8];
        val[0] = i as u8;
        w.append(i * 1000, val).unwrap();
    }
    let file = File::create(dir.join("with_metadata.golf")).unwrap();
    w.seal(file).unwrap();
    println!("  with_metadata.golf: 10 records, with metadata");
}
