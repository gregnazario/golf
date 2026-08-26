# Cross-Language Compatibility

All Golf implementations (Rust, Go, Python, TypeScript, Swift, Kotlin) are
byte-compatible: a `.golf` file written by any implementation that supports a
given codec can be read by every other implementation supporting the same
codec. This document explains how that is guaranteed and what to do when
adding or changing an implementation.

## Codec Support Matrix

| Codec                | Rust | Go | Python | TypeScript | Swift | Kotlin |
|----------------------|:----:|:--:|:------:|:----------:|:-----:|:------:|
| `none` (0)           | R/W  | R/W | R/W   | R/W        | R/W   | R/W    |
| LZ4 block (1)        | R/W  | R/W | R/W   | R/W¹       | R/W¹  | R/W¹   |
| Zstandard frame (2)  | R/W  | R/W | R/W   | error²     | error² | error² |

1. Written using each implementation's own encoder, but always in the raw LZ4
   *block* format with a 4-byte little-endian uncompressed-size prefix (the
   "prepend size" convention of Rust's `lz4_flex`). Any conformant decoder --
   including `liblz4`, `klauspost/compress`, `python-lz4`, and `lz4js` --
   reads it.
2. These runtimes have no low-friction Zstd dependency, so instead of silently
   misreading they raise an explicit unsupported-codec error when a query would
   need to decompress a Zstd block. Opening and inspecting such files (header,
   metadata, index) still works; only decompression fails.

## Integrity Model

Every implementation validates identically:

- **Open time**: footer magic + CRC32C → block-index CRC32C → header magic +
  version + CRC32C → metadata decoding.
- **Query time**: for each block actually touched by the range, the
  *uncompressed* bytes are verified against the descriptor's `block_crc`.

Data-block corruption therefore surfaces on first read of the affected block,
not at open -- readers never pay decompression cost for blocks a query does
not touch.

## Conventions Every Implementation Follows

- All integers little-endian; timestamps unsigned 64-bit.
- Records stored ascending by timestamp within blocks; duplicates allowed with
  unspecified tie order (writers may reorder ties).
- Writer is append-then-seal: sealing consumes/singles-shots the writer.
- Value size must equal `record_value_size` exactly.
- LZ4 payloads are `[u32 LE uncompressed_size][lz4_block]`.
- Zstd payloads are a standard single-frame stream (`level 3` in reference
  writers is conventional but not required).

## Fixture Suite

`testdata/run_compat_tests.sh` regenerates all fixtures from every language,
then runs each language's test suite against all of them:

1. **Generation** -- each `<lang>/...generate_fixtures` writes three files:
   - `<lang>_small.golf`: 20 records, `record_value_size=8`,
     `block_capacity=4`, no compression, nanosecond timestamps at `i*1000`,
     value byte 0 equals record index.
   - `<lang>_lz4.golf`: 100 records, value size 16, capacity 8, LZ4,
     microsecond timestamps at `i*500`, value byte 0/1 = little-endian index.
   - `<lang>_metadata.golf`: 10 records plus metadata entries
     `{source: <lang>-generator, version: 0.1.0}`.
2. **Validation** -- each language opens every fixture (except its own
   unsupported-codec cases) and asserts:
   - header/descriptor bookkeeping consistency (`record_count` == sum of block
     counts);
   - full-range query returns exactly `record_count` records;
   - min/max query results match the declared timestamp range;
   - for every `*_small.golf`, the exact generator contract above holds,
     cross-checked between all six languages.

The shared fixtures make regressions visible immediately: if one
implementation drifts from the format, five others fail while reading it.

Zstd coverage exists via `small.golf` companions written by Rust/Go/Python
(`compressed_zstd.golf`); TypeScript/Swift/Kotlin tests assert a clean
unsupported-codec error for it rather than skipping silently.

## Adding a New Language Implementation

Checklist (see CONTRIBUTING.md for workflow details):

1. Implement writer + reader per [SPEC.md](../SPEC.md). Reference flow:
   `rust/src/writer.rs` (sealing) and `rust/src/reader.rs` (range query).
2. Validate CRCs exactly as specified ("Integrity Model" above).
3. Provide a `generate_fixtures` executable producing the three fixtures named
   `<yourlang>_{small,lz4,metadata}.golf` with the parameters listed above.
4. Add unit tests mirroring `swift/Tests/GolfTests/GolfTests.swift`:
   round-trips, CRC known-answer tests (`"123456789"` → `0xE3069283`),
   corruption detection, and reading all `testdata/*.golf` fixtures.
5. Wire generation + test steps into `testdata/run_compat_tests.sh`
   (skip-if-toolchain-missing pattern used by the Swift/Kotlin steps).
6. Add your row to the matrices in this document and the root README, and a
   `<language>/README.md` documenting install + API.
