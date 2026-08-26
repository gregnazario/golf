# Golf for Kotlin/JVM

Implementation of the [Golf format](../SPEC.md) -- a read-only indexed binary
file format for time-series range queries -- for the JVM with **zero
third-party dependencies**: checksums use the JDK's hardware-accelerated
`java.util.zip.CRC32C` and the LZ4 raw-block codec is implemented in-package.

## Installation

The library ships as ordinary sources/jar; there is no Maven artifact yet.

- **Without Gradle** (recommended for this repo -- fully offline):

  ```bash
  bash scripts/build.sh          # produces .build/golf.jar (+ golf-tests.jar)
  ```

  Add `.build/golf.jar` to your classpath.

- **With Gradle** (convenience; needs network on first run):

  ```bash
  cd kotlin && gradle build
  ```

## Quick Start

### Writing

```kotlin
import golf.*
import java.io.File

val writer = GolfWriter(
    WriterConfig(
        recordValueSize = 8,                              // required
        tsResolution = TimestampResolution.NANOSECONDS,   // default NANOSECONDS
        compression = Compression.LZ4,                    // default LZ4
        blockCapacity = 8192,                             // default 8192
        metadata = listOf(MetadataEntry("source", "ingest-7")),
    ),
)

writer.append(2000UL, ByteArray(8) { 2 })   // any order ok
writer.append(1000UL, ByteArray(8) { 1 })   // value.size must equal recordValueSize

writer.sealTo(File("data.golf"))            // one-shot; or val image = writer.seal()
```

Sealing sorts by timestamp ascending, partitions into blocks of at most
`blockCapacity`, compresses each independently, writes index + footer, then
refuses further use.

### Reading

```kotlin
import golf.*

val reader = GolfReader.open("data.golf")           // or fromBytes(byteArray)

println(reader.recordCount)                         // ULong
println(reader.timestampRange)                      // ClosedRange<ULong>
println(reader.metadata)                            // List<MetadataEntry>

val hits = reader.query(1000UL, 2000UL)             // inclusive range, ascending
for (r in hits) println(r.timestamp, r.value.joinToString(","))

val page = reader.query(5_000_000UL..5_100_000UL)   // ClosedRange overload
```

## Validation Behavior

- **On open** (`fromBytes`/`open`): footer magic/CRC32C → block-index CRC32C →
  header magic/version/CRC32C → metadata decoding.
- **Per query**: touched blocks are decompressed and their *uncompressed*
  CRC32C verified before records are returned; untouched blocks are never
  read.

All failures throw `GolfException` with descriptive messages
(`"header CRC mismatch"`, `"value size mismatch: expected X, got Y"`,
`"LZ4 produced N bytes, expected M"`, ...).

## API Reference

| Declaration                                            | Description                             |
|--------------------------------------------------------|-----------------------------------------|
| `data class WriterConfig(recordValueSize, tsResolution, compression, blockCapacity, metadata)` | Options |
| `class GolfWriter(config)`                              |                                         |
| `.append(timestamp: ULong, value: ByteArray)`          | Buffers one record (defensive copy)     |
| `.count: Int`                                          | Buffered count                          |
| `.seal(): ByteArray` / `.sealTo(File)`                 | One-shot finalize                       |
| `class GolfReader`                                     |                                         |
| `GolfReader.open(path)` / `.open(File)` / `.fromBytes(bytes)` | Constructors (validate immediately) |
| `.header` / `.metadata` / `.descriptors`               | Parsed structures                       |
| `.recordCount: ULong` / `.timestampRange`              | Conveniences                            |
| `.query(startTs: ULong, endTs: ULong)` / `.query(ClosedRange<ULong>)` | Range queries            |
| `data class Record(timestamp: ULong, value: ByteArray)` | One sample (structural equality)      |
| Enums `TimestampResolution` / `Compression` (`code: UByte`) | Header fields                        |
| Data classes `GolfHeader`, `BlockDescriptor`, `Footer`, `MetadataEntry` with `encode()`/`decode()` | Wire structs |
| `object Crc32c.checksum(...)`, `object Lz4Block.{compress,decompress}` | Primitives               |
| Top-level `encodeMetadata` / `decodeMetadata`, internal search helpers | Spec primitives          |

## Codec Support & Notes

- **LZ4**: in-package encoder/decoder for the raw LZ4 *block* format with the
  repository-wide `[u32 LE uncompressed size]` prefix — bit-compatible with
  every other implementation's output (proven by the shared fixture suite).
- **Zstd**: not bundled. Queries needing Zstd decompression raise a clear
  `GolfException`; opening such files still works. Writing `.zstd` configs is
  rejected up front.
- Timestamps are `ULong`, preserving full unsigned ordering even past 2^63.

## Testing & Fixtures

```bash
bash scripts/test.sh                    # build + run full suite against ../testdata
bash scripts/generate-fixtures.sh       # regenerate kotlin_*.golf shared fixtures
bash ../testdata/run_compat_tests.sh    # six-language compatibility matrix
```

The test runner needs nothing but `kotlinc` + `java`. Suites cover CRC32C
known answers, LZ4 adversarial inputs, writer/reader semantics, corruption
detection, and reading every fixture generated by the other five languages.

A standard Gradle layout (`src/main/kotlin`, `src/test/kotlin`) is provided so
IDEs import the project natively: `gradle run` (alias `gradle generateFixtures`)
regenerates this language's fixtures, and `gradle runTestSuite` executes the
same self-contained suite — no JUnit dependency involved. For day-to-day work
the offline `scripts/` wrappers do both without downloading anything.
