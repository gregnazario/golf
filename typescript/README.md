# Golf for TypeScript (Node.js)

Implementation of the [Golf format](../SPEC.md) -- a read-only indexed binary
file format for time-series range queries -- for Node.js, using `BigInt`
timestamps.

## Installation

```bash
npm install ./typescript        # from within this repository
```

Dependencies: `lz4js` (LZ4), `crc-32` (CRC32C). Requires Node.js with
`node:zlib`; timestamps are `bigint` because JS numbers cannot represent all
uint64 values exactly.

**Codec support:** write/read `none` + LZ4, read of Zstd files is *not*
supported and raises an explicit error (see ../docs/COMPATIBILITY.md).

## Quick Start

### Writing

```typescript
import fs from 'node:fs';
import { GolfWriter, Compression } from 'golf-format';

const writer = new GolfWriter({
  recordValueSize: 8,             // required
  // tsResolution?: TimestampResolution  (default Nanoseconds)
  compression: Compression.Lz4,   // default Lz4
  blockCapacity: 8192,            // default 8192
  metadata: [{ key: 'source', value: 'ingest-7' }],   // MetadataEntry[]
});

writer.append(2000n, Buffer.alloc(8, 2));   // any order ok
writer.append(1000n, Buffer.alloc(8, 1));   // value.length must equal recordValueSize

fs.writeFileSync('data.golf', writer.seal());   // seal() returns the complete file image
```

Sealing is one-shot; further appends or seals throw.

### Reading

```typescript
import { GolfReader } from 'golf-format';

const reader = GolfReader.open('data.golf');       // from path (file loaded into memory)

console.log(reader.recordCount);                    // bigint
console.log(reader.timestampRange);                 // [minTs, maxTs] bigints
console.log(reader.metadata);                       // MetadataEntry[]

const hits = reader.query(1000n, 2000n);            // inclusive, ascending
for (const r of hits) console.log(r.timestamp, r.value);

const inMemory = GolfReader.fromBuffer(buf);        // from an existing Buffer
```

## Validation Behavior

- **On open**: footer magic/CRC32C → block-index CRC32C → header
  magic/version/CRC32C; metadata decoded.
- **Per query**: each block overlapped by the range is decompressed, its
  CRC32C checked against the uncompressed bytes, then binary-searched to the
  exact boundaries. Blocks outside the query are never touched.

Errors are thrown as standard `Error`s with descriptive messages
(`"header CRC mismatch ..."`, `"block CRC mismatch ..."`,
`"value size mismatch: ..."`, ...).

## API Reference

| Export                                         | Description                              |
|------------------------------------------------|------------------------------------------|
| `new GolfWriter(config: WriterConfig)`         | Config: `recordValueSize` (required), `tsResolution?`, `compression?`, `blockCapacity?`, `metadata?` |
| `.append(timestamp: bigint, value: Buffer)`    | Buffer one record                        |
| `.length`                                      | Buffered record count                    |
| `.seal(): Buffer`                              | Complete `.golf` image                   |
| `GolfReader.open(path)` / `.fromBuffer(data)`  | Open + validate                          |
| `.recordCount: bigint`                         | From validated header                    |
| `.timestampRange: [bigint, bigint]`            | Inclusive span                           |
| `.metadata: MetadataEntry[]`                   | Decoded key/value pairs                  |
| `.descriptors: BlockDescriptor[]`              | Block index                              |
| `.query(startTs: bigint, endTs: bigint): Record[]` | Inclusive ascending range           |
| `Record { timestamp: bigint; value: Buffer }`  | One sample                               |
| `Header`, `BlockDescriptor`, `Footer`, `MetadataEntry` | Wire structs                     |
| Enums `Compression` (`None/Lz4/Zstd`), `TimestampResolution` (`Nanoseconds/Microseconds/Milliseconds`) | Header fields |
| Constants `FIXED_HEADER_SIZE`, `BLOCK_DESCRIPTOR_SIZE`, `FOOTER_SIZE`, `FORMAT_VERSION`, `HEADER_MAGIC`, `FOOTER_MAGIC` | Spec constants |
| Encoding primitives (`encodeHeader`, `decodeFooter`, `computeCrc32c`, `binarySearchFirst`, ...) | Mirror SPEC.md |

`MmapGolfReader` is exported as an alias of `GolfReader`: buffer-backed reads
fill the same role as memory mapping on the JS runtime.

## Building & Testing

```bash
npm install          # dev deps include typescript + tsx
npm run build        # tsc -> dist/
npm test             # node:test suite via tsx

npx tsx src/generate_fixtures.ts ../testdata   # regenerate ts_*.golf fixtures
bash ../testdata/run_compat_tests.sh           # full cross-language matrix
```

Tests cover round-trips both compressed and raw, boundary narrowing, metadata,
corruption handling, and reading every fixture produced by the other five
languages (Zstd fixtures assert the explicit unsupported-codec error).
