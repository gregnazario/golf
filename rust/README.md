# Golf for Rust (reference implementation)

The canonical implementation of the [Golf format](../SPEC.md): a read-only,
indexed binary file format for range queries over time-series records.
Everything else in this repository is validated against this crate.

## Installation

```toml
[dependencies]
golf = { path = "../rust" }          # within this repository
```

Dependencies: `crc32c`, `lz4_flex`, `zstd`, `memmap2`, `thiserror`.

Requires Rust 2021 edition.

## Quick Start

### Writing

```rust
use golf::{GolfWriter};
use golf::writer::WriterConfig;
use golf::header::{Compression, TimestampResolution};

let mut writer = GolfWriter::new(WriterConfig {
    record_value_size: 8,                       // required
    ts_resolution: TimestampResolution::Nanoseconds, // default Nanoseconds
    compression: Compression::Lz4,              // default Lz4
    block_capacity: 8192,                       // default 8192
    metadata: vec![],                           // default empty
    ..Default::default()
});

// Append in any order; values must be exactly `record_value_size` bytes.
writer.append(2000, vec![2u8; 8])?;
writer.append(1000, vec![1u8; 8])?;

let file = std::fs::File::create("data.golf")?;
writer.seal(file)?;     // consumes the writer; sealing is one-shot
```

Sealing sorts all buffered records by timestamp ascending, partitions them
into blocks of at most `block_capacity`, compresses each block independently,
and writes header + blocks + index + footer.

### Reading (standard I/O)

```rust
use golf::GolfReader;

let mut reader = GolfReader::open_path("data.golf")?;

println!("{}", reader.record_count());        // total records
println!("{:?}", reader.timestamp_range());   // (min_ts, max_ts)
println!("{:?}", reader.metadata());          // decoded key/value entries

// Inclusive range query; only overlapping blocks are decompressed.
for record in reader.query(1_000, 2_000)? {
    println!("{} = {:?}", record.timestamp, record.value);
}
```

Opening validates the footer magic + CRC32C, block-index CRC32C, and header
magic/version/CRC32C. Each block's data CRC is verified lazily when the block
is first touched by a query.

`GolfReader<R: Read + Seek>` works over any seekable source
(`File`, `Cursor<Vec<u8>>`, ...). Use `GolfReader::open(cursor)` for bytes.

### Reading (mmap)

```rust
use golf::MmapGolfReader;

let file = std::fs::File::open("data.golf")?;
let reader = MmapGolfReader::open(&file)?;

let hot = reader.query(5_000, 9_000)?;   // zero-copy reads on mapped pages
```

Prefer `MmapGolfReader` when repeatedly issuing queries over large files; it
avoids syscall-per-block and lets the OS page cache do the work.

## API Reference

| Item                                   | Description                                        |
|----------------------------------------|----------------------------------------------------|
| `WriterConfig { .. }`                  | Writer options (see example)                       |
| `GolfWriter::new(config)`              | Create a writer                                     |
| `.append(timestamp: u64, value: Vec<u8>)` | Buffer one record (`WriterError::ValueSize...` on mismatch) |
| `.len() / .is_empty()`                 | Buffered record count                              |
| `.seal(dest: W: Write)`                | Consume writer, write complete file                |
| `GolfReader::open_path(path)` / `::open(r)` | Open + validate                                |
| `.header()` / `.metadata()` / `.index()` | Access parsed structures                          |
| `.query(start_ts, end_ts) -> Vec<Record>` | Inclusive ascending range                        |
| `.record_count()` / `.timestamp_range()` | Header-derived conveniences                        |
| `Record { timestamp: u64, value: Vec<u8> }` | One sample                                    |
| `Header`, `BlockDescriptor`, `MetadataEntry`, `Footer` | Wire structs (see SPEC.md)          |

Error enums: `WriterError`, `ReaderError` (thiserror-derived).

## Codec Notes

- **LZ4**: raw *block* format via `lz4_flex` with prepended uncompressed size
  (`compress_prepend_size`) -- byte-compatible with every other language here.
- **Zstd**: single standard frame, default level.

## Testing

```bash
cargo test                                   # unit + integration
cargo run --bin generate_fixtures            # regenerate rust_*/compressed_* fixtures into ../testdata
bash ../testdata/run_compat_tests.sh         # full six-language matrix
```

`tests/compat.rs` reads every fixture under `testdata/`, including files
produced by Go, Python, TypeScript, Swift, and Kotlin.
