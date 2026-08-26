# Golf for Python

Pure-Python implementation of the [Golf format](../SPEC.md) -- a read-only
indexed binary file format for time-series range queries -- with standard-I/O
and `mmap`-backed readers.

## Installation

```bash
pip install ./python          # from within this repository (PyPI: golf-format)
```

Requires Python ≥ 3.9. Dependencies: `crc32c`, `lz4` (`python-lz4`),
`zstandard`. Dev extra adds `pytest`.

## Quick Start

### Writing

```python
from golf import GolfWriter, WriterConfig, Compression, TimestampResolution, MetadataEntry

writer = GolfWriter(WriterConfig(
    record_value_size=8,                            # required
    ts_resolution=TimestampResolution.NANOSECONDS,  # default NANOSECONDS
    compression=Compression.LZ4,                    # default LZ4 in examples; dataclass default NONE
    block_capacity=8192,
    metadata=[MetadataEntry(key="source", value="ingest-7")],
))

writer.append(2000, b"\x02" * 8)   # any order ok
writer.append(1000, b"\x01" * 8)   # len(value) must equal record_value_size

with open("data.golf", "wb") as f:
    writer.seal(f)                 # sorts, blocks, compresses, writes index+footer
```

Sealing is one-shot: the writer refuses further appends afterwards.

### Reading

```python
from golf import GolfReader

with GolfReader.open("data.golf") as reader:
    print(reader.record_count)        # int
    print(reader.timestamp_range)     # (min_ts, max_ts)
    print(reader.metadata)            # list[MetadataEntry]

    records = reader.query(1000, 2000)     # inclusive range, ascending
    hot = reader.query(1500, 1500)         # point query == degenerate range
```

For tight loops over large files prefer the mmap variant:

```python
from golf import MmapGolfReader

with MmapGolfReader("data.golf") as reader:
    page = reader.query(5_000_000, 5_100_000)
```

## Validation Behavior

- **On open**: footer magic/CRC → block-index CRC → header magic/version/CRC;
  metadata decoded.
- **Per query**: touched blocks are decompressed and their uncompressed CRC32C
  verified before any record is returned. Corrupt blocks raise
  `ValueError("block CRC mismatch ...")` on first access.

All decode failures raise `ValueError` with a descriptive message.

## API Reference

| Object                                        | Description                                 |
|-----------------------------------------------|---------------------------------------------|
| `WriterConfig(record_value_size, ts_resolution, compression, block_capacity, metadata)` | Writer options |
| `GolfWriter(config)`                          |                                             |
| `.append(timestamp: int, value: bytes)`       | Buffers one record                          |
| `len(writer)`                                 | Buffered count                              |
| `.seal(dest: BinaryIO)`                       | Writes the complete file                    |
| `GolfReader.open(path) -> GolfReader`         | Context-manager file reader                 |
| `MmapGolfReader(path) -> MmapGolfReader`      | Context-manager mmap reader                 |
| `.record_count` / `.timestamp_range` / `.metadata` / `.header` | Parsed header info         |
| `.query(start_ts, end_ts) -> list[Record]`    | Inclusive ascending range                   |
| `Record(timestamp: int, value: bytes)`        | One sample                                  |
| `Header`, `BlockDescriptor`, `MetadataEntry`, `Footer` | Wire structs with `.encode()`/`.decode()` |
| `compute_crc32c(data)`, `encode_metadata`, `decode_metadata`, `compress_block`, `decompress_block`, `serialize_block`, `parse_records`, `find_first_block`, `find_last_block` | Primitives mirroring SPEC.md |

## Testing

```bash
cd python
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest

# Regenerate this language's shared fixtures:
python -m golf.generate_fixtures ../testdata

# Full six-language compatibility matrix:
bash ../testdata/run_compat_tests.sh
```

## Notes & Limitations

- Timestamps are unsigned 64-bit ints and are compared as such.
- LZ4 uses `lz4.block` with the repository-wide prepend-size convention;
  Zstd is a single standard frame at level 3 on write.
