//! Integration tests for the golf file format.

use golf::header::{Compression, MetadataEntry, TimestampResolution};
use golf::reader::{GolfReader, MmapGolfReader};
use golf::writer::{GolfWriter, WriterConfig};
use std::io::Cursor;
use tempfile::NamedTempFile;

/// Helper: build a golf file in memory with given records and config.
fn build_in_memory(
    records: &[(u64, Vec<u8>)],
    config: WriterConfig,
) -> Vec<u8> {
    let mut w = GolfWriter::new(config.clone());
    for (ts, val) in records {
        w.append(*ts, val.clone()).unwrap();
    }
    let mut buf = Vec::new();
    w.seal(&mut buf).unwrap();
    buf
}

fn make_value(seed: u8, size: usize) -> Vec<u8> {
    (0..size).map(|i| seed.wrapping_add(i as u8)).collect()
}

// ── Basic round-trip tests ──

#[test]
fn test_roundtrip_no_compression() {
    let config = WriterConfig {
        record_value_size: 16,
        compression: Compression::None,
        block_capacity: 4,
        ts_resolution: TimestampResolution::Nanoseconds,
        metadata: vec![],
    };

    let records: Vec<(u64, Vec<u8>)> = (0..10)
        .map(|i| (i * 1000, make_value(i as u8, 16)))
        .collect();

    let data = build_in_memory(&records, config);
    let mut reader = GolfReader::open(Cursor::new(&data)).unwrap();

    assert_eq!(reader.record_count(), 10);
    assert_eq!(reader.timestamp_range(), (0, 9000));

    // Query all
    let result = reader.query(0, 9000).unwrap();
    assert_eq!(result.len(), 10);
    for (i, rec) in result.iter().enumerate() {
        assert_eq!(rec.timestamp, i as u64 * 1000);
        assert_eq!(rec.value, make_value(i as u8, 16));
    }
}

#[test]
fn test_roundtrip_lz4() {
    let config = WriterConfig {
        record_value_size: 32,
        compression: Compression::Lz4,
        block_capacity: 8,
        ts_resolution: TimestampResolution::Microseconds,
        metadata: vec![],
    };

    let records: Vec<(u64, Vec<u8>)> = (0..100)
        .map(|i| (i * 500, make_value(i as u8, 32)))
        .collect();

    let data = build_in_memory(&records, config);
    let mut reader = GolfReader::open(Cursor::new(&data)).unwrap();

    assert_eq!(reader.record_count(), 100);

    // Query subset
    let result = reader.query(5000, 10000).unwrap();
    let expected: Vec<u64> = (10..=20).map(|i| i * 500).collect();
    let got: Vec<u64> = result.iter().map(|r| r.timestamp).collect();
    assert_eq!(got, expected);
}

#[test]
fn test_roundtrip_zstd() {
    let config = WriterConfig {
        record_value_size: 8,
        compression: Compression::Zstd,
        block_capacity: 16,
        ts_resolution: TimestampResolution::Milliseconds,
        metadata: vec![],
    };

    let records: Vec<(u64, Vec<u8>)> = (0..50)
        .map(|i| (i * 100, vec![i as u8; 8]))
        .collect();

    let data = build_in_memory(&records, config);
    let mut reader = GolfReader::open(Cursor::new(&data)).unwrap();

    assert_eq!(reader.record_count(), 50);

    // Query single point
    let result = reader.query(2500, 2500).unwrap();
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].timestamp, 2500);
    assert_eq!(result[0].value, vec![25u8; 8]);
}

// ── Range query edge cases ──

#[test]
fn test_query_empty_range() {
    let config = WriterConfig {
        record_value_size: 8,
        compression: Compression::None,
        block_capacity: 4,
        ..Default::default()
    };

    let records: Vec<(u64, Vec<u8>)> = (0..10)
        .map(|i| (i * 100, vec![0u8; 8]))
        .collect();

    let data = build_in_memory(&records, config);
    let mut reader = GolfReader::open(Cursor::new(&data)).unwrap();

    // Query before all records
    let result = reader.query(0, 0).unwrap();
    assert_eq!(result.len(), 1); // ts=0 exists
    assert_eq!(result[0].timestamp, 0);

    // Query after all records
    let result = reader.query(1000, 2000).unwrap();
    assert_eq!(result.len(), 0);

    // Query in gap
    let result = reader.query(50, 99).unwrap();
    assert_eq!(result.len(), 0);
}

#[test]
fn test_query_full_range() {
    let config = WriterConfig {
        record_value_size: 8,
        compression: Compression::Lz4,
        block_capacity: 4,
        ..Default::default()
    };

    let records: Vec<(u64, Vec<u8>)> = (0..20)
        .map(|i| (i * 10, vec![i as u8; 8]))
        .collect();

    let data = build_in_memory(&records, config);
    let mut reader = GolfReader::open(Cursor::new(&data)).unwrap();

    let result = reader.query(0, u64::MAX).unwrap();
    assert_eq!(result.len(), 20);
}

#[test]
fn test_unsorted_input() {
    // Writer should sort records regardless of insertion order
    let config = WriterConfig {
        record_value_size: 4,
        compression: Compression::None,
        block_capacity: 4,
        ..Default::default()
    };

    let mut w = GolfWriter::new(config);
    w.append(300, vec![3, 0, 0, 0]).unwrap();
    w.append(100, vec![1, 0, 0, 0]).unwrap();
    w.append(200, vec![2, 0, 0, 0]).unwrap();
    w.append(500, vec![5, 0, 0, 0]).unwrap();
    w.append(400, vec![4, 0, 0, 0]).unwrap();

    let mut buf = Vec::new();
    w.seal(&mut buf).unwrap();
    let mut reader = GolfReader::open(Cursor::new(&buf)).unwrap();

    let result = reader.query(0, 600).unwrap();
    let timestamps: Vec<u64> = result.iter().map(|r| r.timestamp).collect();
    assert_eq!(timestamps, vec![100, 200, 300, 400, 500]);
}

// ── Metadata tests ──

#[test]
fn test_metadata_roundtrip() {
    let config = WriterConfig {
        record_value_size: 8,
        compression: Compression::None,
        block_capacity: 4,
        metadata: vec![
            MetadataEntry {
                key: "source".into(),
                value: "test-suite".into(),
            },
            MetadataEntry {
                key: "version".into(),
                value: "1.0.0".into(),
            },
        ],
        ..Default::default()
    };

    let records: Vec<(u64, Vec<u8>)> = (0..5)
        .map(|i| (i * 100, vec![0u8; 8]))
        .collect();

    let data = build_in_memory(&records, config);
    let reader = GolfReader::open(Cursor::new(&data)).unwrap();

    let meta = reader.metadata();
    assert_eq!(meta.len(), 2);
    assert_eq!(meta[0].key, "source");
    assert_eq!(meta[0].value, "test-suite");
    assert_eq!(meta[1].key, "version");
    assert_eq!(meta[1].value, "1.0.0");
}

// ── Mmap reader tests ──

#[test]
fn test_mmap_reader() {
    let config = WriterConfig {
        record_value_size: 16,
        compression: Compression::Lz4,
        block_capacity: 8,
        ..Default::default()
    };

    let records: Vec<(u64, Vec<u8>)> = (0..50)
        .map(|i| (i * 100, make_value(i as u8, 16)))
        .collect();

    // Write to a temp file
    let tmp = NamedTempFile::new().unwrap();
    let mut w = GolfWriter::new(config);
    for (ts, val) in &records {
        w.append(*ts, val.clone()).unwrap();
    }
    w.seal(tmp.as_file().try_clone().unwrap()).unwrap();

    // Read with mmap
    let reader = MmapGolfReader::open_path(tmp.path()).unwrap();
    assert_eq!(reader.record_count(), 50);

    let result = reader.query(1000, 2000).unwrap();
    let timestamps: Vec<u64> = result.iter().map(|r| r.timestamp).collect();
    let expected: Vec<u64> = (10..=20).map(|i| i * 100).collect();
    assert_eq!(timestamps, expected);
}

// ── Duplicate timestamp tests ──

#[test]
fn test_duplicate_timestamps() {
    let config = WriterConfig {
        record_value_size: 4,
        compression: Compression::None,
        block_capacity: 4,
        ..Default::default()
    };

    let mut w = GolfWriter::new(config);
    for i in 0..5u8 {
        w.append(100, vec![i, 0, 0, 0]).unwrap();
    }
    w.append(200, vec![5, 0, 0, 0]).unwrap();

    let mut buf = Vec::new();
    w.seal(&mut buf).unwrap();
    let mut reader = GolfReader::open(Cursor::new(&buf)).unwrap();

    let result = reader.query(100, 100).unwrap();
    assert_eq!(result.len(), 5);
    for rec in &result {
        assert_eq!(rec.timestamp, 100);
    }

    let result = reader.query(100, 200).unwrap();
    assert_eq!(result.len(), 6);
}

// ── Large dataset test ──

#[test]
fn test_many_records() {
    let config = WriterConfig {
        record_value_size: 8,
        compression: Compression::Lz4,
        block_capacity: 1024,
        ..Default::default()
    };

    let n = 100_000u64;
    let mut w = GolfWriter::new(config);
    for i in 0..n {
        w.append(i, vec![(i & 0xff) as u8; 8]).unwrap();
    }

    let mut buf = Vec::new();
    w.seal(&mut buf).unwrap();
    let mut reader = GolfReader::open(Cursor::new(&buf)).unwrap();

    assert_eq!(reader.record_count(), n);

    // Query a small window
    let result = reader.query(50_000, 50_099).unwrap();
    assert_eq!(result.len(), 100);
    assert_eq!(result[0].timestamp, 50_000);
    assert_eq!(result[99].timestamp, 50_099);
}
