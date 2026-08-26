# Golf for Go

Implementation of the [Golf format](../SPEC.md) -- a read-only indexed binary
file format for time-series range queries -- with both standard-I/O and
memory-mapped readers.

## Installation

```
go get github.com/golf-format/golf-go
```

Package import path:

```go
import golf "github.com/golf-format/golf-go"
```

Dependencies: `github.com/klauspost/compress` (zstd),
`github.com/pierrec/lz4/v4`. Requires Go 1.21+.

## Quick Start

### Writing

```go
w := golf.NewWriter(golf.WriterConfig{
    RecordValueSize: 8,                    // required
    TsResolution:    golf.TsNanoseconds,   // default TsNanoseconds
    Compression:     golf.CompressionLz4,  // default CompressionLz4
    BlockCapacity:   8192,                 // default 8192
    Metadata: []golf.MetadataEntry{        // optional header metadata
        {Key: "source", Value: "ingest-7"},
    },
})

w.Append(2000, []byte{2,2,2,2,2,2,2,2})   // any order ok
w.Append(1000, []byte{1,1,1,1,1,1,1,1})   // value length must equal RecordValueSize

f, err := os.Create("data.golf")
if err != nil { ... }
if err := w.Seal(f); err != nil { ... }   // sorts, blocks, indexes, writes footer
```

Sealing consumes the writer; calling anything afterwards returns an error.

### Reading (standard I/O)

```go
reader, err := golf.OpenFile("data.golf")
if err != nil { ... }

records, err := reader.Query(1000, 2000)  // inclusive range
for _, r := range records {
    fmt.Println(r.Timestamp, r.Value)
}
```

`OpenReader(rs io.ReadSeeker)` accepts any seekable reader, e.g.
`bytes.NewReader(buf)` for in-memory use.

### Reading (mmap)

```go
mreader, err := golf.OpenMmap("data.golf")
defer mreader.Close()

records, err := mreader.Query(0, 1<<62)   // all records
```

## Validation Behavior

Matching the spec's integrity model:

- **On open**: footer magic/CRC → block-index CRC → header magic/version/CRC;
  metadata decoded.
- **Per query**: each block actually touched is decompressed (if needed) and
  its *uncompressed* CRC32C verified before records are returned.

A corrupt block surfaces as an error from the first query that needs it; open
never touches block payloads.

## API Reference

Types (all little-endian wire forms documented in SPEC.md):

| Type                                                      | Purpose                     |
|-----------------------------------------------------------|-----------------------------|
| `Record { Timestamp uint64; Value []byte }`               | One sample                  |
| `Header`, `Footer`, `BlockDescriptor`, `MetadataEntry`    | Wire structures             |
| `TimestampResolution` (`TsNanoseconds/TsMicroseconds/TsMilliseconds`) | Header field    |
| `Compression` (`CompressionNone/CompressionLz4/CompressionZstd`)       | Header field    |

Writer:

| Function / Method                                | Notes                                  |
|--------------------------------------------------|----------------------------------------|
| `NewWriter(config WriterConfig) *GolfWriter`     |                                        |
| `(*GolfWriter).Append(ts uint64, value []byte)`  | Validates value size                   |
| `(*GolfWriter).Len()`                            | Buffered count                         |
| `(*GolfWriter).Seal(dest io.Writer) error`       | Consumes writer                        |
| `EncodeHeader / DecodeHeader`, `EncodeMetadata / DecodeMetadata`, `EncodeBlockDescriptor / DecodeBlockDescriptor`, `EncodeFooter / DecodeFooter` | Exposed primitives mirroring SPEC.md |

Reader:

| Function / Method                                     | Notes                      |
|-------------------------------------------------------|----------------------------|
| `OpenFile(path) (*GolfReader, error)`                 | File-backed                |
| `OpenReader(io.ReadSeeker) (*GolfReader, error)`      | Any seekable source        |
| `(*GolfReader).Query(startTs, endTs uint64)`          | Inclusive ascending range  |
| `OpenMmap(path) (*MmapGolfReader, error)`             | Memory-mapped variant      |
| `(*MmapGolfReader).Query(startTs, endTs uint64)`      | Same contract              |
| `(*MmapGolfReader).Close()`                           | Unmaps                     |

Binary-search helpers `FindFirstBlock` / `FindLastBlock` are exported for
tooling that wants to inspect indexes directly.

## Testing

```bash
go test ./...
go run ./cmd/generate_fixtures ../testdata    # regenerate go_*.golf fixtures
bash ../testdata/run_compat_tests.sh          # cross-language matrix
```

`golf_test.go` covers round-trips, corruption handling, and reads every shared
fixture in `testdata/`.
