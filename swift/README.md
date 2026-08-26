# Golf for Swift

Implementation of the [Golf format](../SPEC.md) -- a read-only indexed binary
file format for time-series range queries -- as a SwiftPM package with **zero
third-party dependencies**: CRC32C and an LZ4 raw-block codec are implemented
in-package, so it builds anywhere SwiftPM does, including offline CI.

## Installation

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(path: "../swift")     // within this repository
],
targets: [
    .target(name: "YourApp", dependencies: ["Golf"]),
]
```

Requires Swift 5.9+; usable on macOS 13+, iOS 16+, and Linux toolchains that
support the language mode.

## Quick Start

### Writing

```swift
import Golf

let writer = GolfWriter(config: WriterConfig(
    recordValueSize: 8,                 // required
    tsResolution: .nanoseconds,         // default .nanoseconds
    compression: .lz4,                  // default .lz4
    blockCapacity: 8192,                // default 8192
    metadata: [MetadataEntry(key: "source", value: "ingest-7")]
))

try writer.append(timestamp: 2000, value: [UInt8](repeating: 2, count: 8))  // any order ok
try writer.append(timestamp: 1000, value: [UInt8](repeating: 1, count: 8))  // value.count must match

let image = try writer.seal()                                   // complete file as [UInt8]
try Data(image).write(to: URL(fileURLWithPath: "data.golf"))

// or in one step:
// try writer.seal(to: URL(fileURLWithPath: "data.golf"))
```

Sealing sorts all records by timestamp ascending, partitions them into blocks
of at most `blockCapacity`, compresses each block independently, writes the
block index and footer, and is strictly one-shot.

There is also a convenience for small fixed-size integer payloads:

```swift
try writer.append(timestamp: 42, intValue: 0x0102030405060708)  // LE-encoded, zero-padded
```

### Reading

```swift
import Golf

let reader = try GolfReader.open("data.golf")
// or: let reader = try GolfReader(contentsOf: someURL)
// or: let reader = try GolfReader(data: imageBytes)

print(reader.recordCount)      // UInt64
print(reader.timestampRange)   // ClosedRange<UInt64>
print(reader.metadata)         // [MetadataEntry]

let hits = try reader.query(start: 1000, end: 2000)   // inclusive range, ascending
for record in hits {
    print(record.timestamp, record.value)
}

let point = try reader.query(1500...1500)             // point query via ClosedRange
```

## Validation Behavior

- **On open** (`init`): footer magic/CRC32C → block-index CRC32C → header
  magic/version/CRC32C → metadata decoding.
- **Per query**: each block overlapped by the requested range is decompressed,
  its uncompressed CRC32C verified, then binary-searched to exact boundaries.
  Untouched blocks are never read.

All failures throw typed errors from `GolfError` (`invalidMagic`,
`crcMismatch`, `unsupportedVersion`, `valueSizeMismatch`, `writerAlreadySealed`,
`compressionError`, ...), so error handling can pattern-match precisely.

## API Reference

| Declaration                                                | Description                          |
|------------------------------------------------------------|--------------------------------------|
| `struct WriterConfig { recordValueSize, tsResolution, compression, blockCapacity, metadata }` | Writer options |
| `final class GolfWriter`                                   |                                      |
| `.append(timestamp: UInt64, value: [UInt8]) throws`        | Buffers one record                   |
| `.append(timestamp: UInt64, intValue: UInt64) throws`      | Convenience integer payload          |
| `.count: Int`                                              | Buffered count                       |
| `.seal() throws -> [UInt8]` / `.seal(to: URL) throws`      | One-shot finalize                    |
| `struct GolfReader`                                        | Value type over loaded bytes         |
| `.open(_ path: String)` / `.init(contentsOf: URL)` / `.init(data:)` | Opening constructors        |
| `.header: GolfHeader` / `.metadata` / `.descriptors`       | Parsed structures                    |
| `.recordCount: UInt64` / `.timestampRange: ClosedRange<UInt64>` | Conveniences                    |
| `.query(start:end:)` / `.query(ClosedRange<UInt64>) throws -> [Record]` | Range queries           |
| `struct Record { timestamp: UInt64; value: [UInt8] }`      | One sample                           |
| Enums `TimestampResolution` / `Compression` (`UInt8` raw values per spec) | Header fields |
| Structs `GolfHeader`, `BlockDescriptor`, `Footer`, `MetadataEntry` with `encode()`/`decode()` | Wire structs |
| Free functions `encodeMetadata`, `decodeMetadata`          | Metadata wire codec                  |

## Codec Support & Notes

- **LZ4**: an in-package greedy compressor and full decoder for the *raw LZ4
  block* format, always written with the repository-wide 4-byte LE
  uncompressed-size prefix. Output is decodable by any conformant LZ4 stack;
  cross-language fixtures prove interop with Go/Python/TypeScript/Rust codecs.
- **Zstd**: not bundled. Reading a Zstd file succeeds at open (header/index
  are intact) but a query that needs to decompress throws
  `GolfError.compressionError(... Zstd ...)`. Write-side rejects `.zstd`
  configuration up front.
- The hash-based compression ratio trails reference liblz4; only decoded bytes
  are contractual, so files remain byte-compatible regardless.

## Testing

```bash
cd swift && swift test              # unit + roundtrip + corruption + fixture suite
swift run GolfFixtures ../testdata  # regenerate swift_*.golf shared fixtures
bash ../testdata/run_compat_tests.sh
```

`Tests/GolfTests/GolfTests.swift` includes CRC32C known-answer tests, LZ4
adversarial cases (RLE runs, extended length codes, corrupt payloads), writer
error paths, and reading of every fixture produced by the other five
languages.
