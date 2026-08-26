# Golf

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A read-only indexed binary file format optimized for range queries over
time-series keys with small fixed-size record values.

Golf files are created by appending records and then sealing the file, after
which they are immutable and efficient for random range reads.

## Key Features

- **Range queries** via binary search over a block index -- O(log B + log N)
- **Block-level compression** (LZ4 or Zstd) -- only touched blocks are decompressed
- **mmap + standard I/O** read strategies
- **Fixed-size records** for O(1) random access within decompressed blocks
- **CRC32C checksums** at header, block, and index levels
- **Configurable timestamp resolution** (nanoseconds, microseconds, milliseconds)
- **Multi-language**: Rust, Go, Python, TypeScript

## File Format

See [SPEC.md](SPEC.md) for the complete byte-level specification.

```
┌──────────────────────┐  offset 0
│       Header         │  64 bytes + optional metadata
├──────────────────────┤
│    Data Block 0      │  compressed
│    Data Block 1      │
│       ...            │
│    Data Block N-1    │
├──────────────────────┤
│     Block Index      │  40 bytes per block descriptor
├──────────────────────┤
│       Footer         │  32 bytes (at EOF)
└──────────────────────┘
```

## Quick Start

### Rust

```rust
use golf::{GolfWriter, GolfReader};
use golf::writer::WriterConfig;
use golf::header::{Compression, TimestampResolution};

// Write
let mut writer = GolfWriter::new(WriterConfig {
    record_value_size: 8,
    compression: Compression::Lz4,
    block_capacity: 8192,
    ..Default::default()
});
writer.append(1000, vec![1u8; 8]).unwrap();
writer.append(2000, vec![2u8; 8]).unwrap();
let file = std::fs::File::create("data.golf").unwrap();
writer.seal(file).unwrap();

// Read
let mut reader = GolfReader::open_path("data.golf").unwrap();
let records = reader.query(1000, 2000).unwrap();
```

### Go

```go
import golf "github.com/golf-format/golf-go"

// Write
w := golf.NewWriter(golf.WriterConfig{
    RecordValueSize: 8,
    Compression:     golf.CompressionLz4,
    BlockCapacity:   8192,
})
w.Append(1000, []byte{1,1,1,1,1,1,1,1})
w.Append(2000, []byte{2,2,2,2,2,2,2,2})
f, _ := os.Create("data.golf")
w.Seal(f)

// Read
reader, _ := golf.OpenFile("data.golf")
records, _ := reader.Query(1000, 2000)
```

### Python

```python
from golf import GolfWriter, GolfReader, WriterConfig, Compression

# Write
writer = GolfWriter(WriterConfig(record_value_size=8, compression=Compression.LZ4))
writer.append(1000, b'\x01' * 8)
writer.append(2000, b'\x02' * 8)
with open('data.golf', 'wb') as f:
    writer.seal(f)

# Read
with GolfReader.open('data.golf') as reader:
    records = reader.query(1000, 2000)
```

### TypeScript

```typescript
import { GolfWriter, GolfReader, Compression } from 'golf-format';

// Write
const writer = new GolfWriter({ recordValueSize: 8, compression: Compression.Lz4 });
writer.append(1000n, Buffer.alloc(8, 1));
writer.append(2000n, Buffer.alloc(8, 2));
fs.writeFileSync('data.golf', writer.seal());

// Read
const reader = GolfReader.open('data.golf');
const records = reader.query(1000n, 2000n);
```

## Installation

Golf packages are **not yet published** -- there is nothing on crates.io, PyPI,
npm, or any Go module registry. For now, install from source and verify each
implementation by running its test suite:

```bash
git clone https://github.com/gregnazario/golf.git
cd golf

# Rust
cd rust && cargo test

# Go
cd ../go && go test ./...

# Python
cd ../python
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]" && pytest

# TypeScript
cd ../typescript && npm install && npm run build && npm test
```

A passing test suite means the implementation is built and usable locally from
its directory (e.g., import `golf` from the activated Python virtualenv, or
import from `typescript/dist/` after building). See [Running Tests](#running-tests)
for details, including the full cross-language compatibility suite.

## Running Tests

```bash
# Rust
cd rust && cargo test

# Go
cd go && go test ./...

# Python
cd python && python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]" && pytest

# TypeScript
cd typescript && npm install && npm test

# Full cross-language compatibility suite
bash testdata/run_compat_tests.sh
```

## Project Structure

```
golf/
  SPEC.md              -- Canonical binary format specification
  rust/                -- Rust implementation (reference)
  go/                  -- Go implementation
  python/              -- Python implementation
  typescript/          -- TypeScript implementation
  testdata/            -- Cross-language test fixtures
```

## License

MIT -- see [LICENSE](LICENSE).
