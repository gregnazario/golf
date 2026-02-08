# Golf File Format Specification

**Version**: 1  
**Status**: Draft  
**Extension**: `.golf`

## Overview

Golf is a read-only, indexed binary file format optimized for range queries over
time-series keys with small fixed-size record values. Files are created by
appending records and then sealing the file, after which it is immutable.

## Conventions

- All multi-byte integers are encoded as **little-endian**.
- All offsets are absolute byte positions from the start of the file.
- Byte numbering is zero-based.
- CRC32 refers to the CRC-32/ISO-HDLC (CRC-32C, Castagnoli) variant.
- Timestamps are unsigned 64-bit integers whose unit is declared in the header.

## File Layout

A `.golf` file consists of four contiguous sections in this order:

```
+---------------------------+  offset 0
|         Header            |
+---------------------------+  offset H
|      Data Block 0         |
+---------------------------+
|      Data Block 1         |
+---------------------------+
|          ...               |
+---------------------------+
|      Data Block N-1       |
+---------------------------+  offset I
|       Block Index         |
+---------------------------+  offset F
|         Footer            |
+---------------------------+  offset F + 32 = EOF
```

## 1. Header

The header has a 64-byte fixed portion followed by optional variable-length
metadata.

### Fixed Header (64 bytes)

| Offset | Size | Field              | Description                                           |
|--------|------|--------------------|-------------------------------------------------------|
| 0      | 4    | `magic`            | ASCII `GOLF` (`0x47 0x4F 0x4C 0x46`)                 |
| 4      | 2    | `version`          | Format version. Currently `1`.                        |
| 6      | 2    | `flags`            | Reserved flags. Must be `0` for version 1.            |
| 8      | 4    | `record_value_size`| Size of each record's value in bytes (excludes the 8-byte timestamp). |
| 12     | 1    | `ts_resolution`    | Timestamp unit: `0` = nanoseconds, `1` = microseconds, `2` = milliseconds. |
| 13     | 1    | `compression`      | Compression codec: `0` = none, `1` = LZ4 (block format), `2` = Zstandard. |
| 14     | 4    | `block_capacity`   | Maximum number of records per data block.             |
| 18     | 10   | `reserved`         | Reserved. Must be zero-filled.                        |
| 28     | 8    | `min_timestamp`    | Minimum timestamp across all records.                 |
| 36     | 8    | `max_timestamp`    | Maximum timestamp across all records.                 |
| 44     | 8    | `record_count`     | Total number of records in the file.                  |
| 52     | 4    | `metadata_length`  | Length in bytes of the variable metadata section. May be `0`. |
| 56     | 4    | `header_crc`       | CRC32C of bytes `0..56` (the preceding 56 bytes).    |
| 60     | 4    | `_padding`         | Reserved padding. Must be zero.                       |

Total fixed header: **64 bytes**.

### Variable Metadata

Immediately following the fixed header at offset 64 are `metadata_length` bytes
of user-defined metadata. The metadata is encoded as a sequence of length-prefixed
key-value pairs:

```
For each pair:
  key_len:   u16    (length of key in bytes)
  key:       [u8]   (UTF-8 key string)
  value_len: u16    (length of value in bytes)
  value:     [u8]   (UTF-8 value string)
```

Readers that do not understand a key MUST ignore it.

The total header size is `64 + metadata_length` bytes.

## 2. Data Blocks

Data blocks begin immediately after the header (at offset `64 + metadata_length`).
Each block stores a contiguous run of records sorted by timestamp in ascending order.

### Uncompressed Block Layout

An uncompressed block is a flat byte array of `record_count * record_size` bytes,
where `record_size = 8 + record_value_size`.

Each record within the block:

| Offset within record | Size                | Field       |
|----------------------|---------------------|-------------|
| 0                    | 8                   | `timestamp` |
| 8                    | `record_value_size` | `value`     |

Records are packed with no padding between them.

### Compression

When `compression != 0`, each block is independently compressed using the codec
specified in the header:

- **LZ4 (1)**: LZ4 block format (not framed). The input is the uncompressed block
  bytes. Implementations should use the standard LZ4 block compress/decompress API.
- **Zstandard (2)**: Single Zstandard frame. Implementations should use the standard
  Zstd compress/decompress API.

When `compression == 0`, blocks are stored uncompressed.

The on-disk size of each block may differ. The exact sizes are recorded in the
block index.

### Ordering Guarantee

All records within a block are sorted by timestamp in ascending order. Across
blocks, block N's `max_timestamp <= block N+1's min_timestamp`. Duplicate
timestamps are permitted and their relative order within that timestamp is
unspecified.

## 3. Block Index

The block index immediately follows the last data block. It is an array of
fixed-size block descriptors, one per data block, in the same order as the
blocks appear in the file.

### Block Descriptor (40 bytes)

| Offset | Size | Field               | Description                                     |
|--------|------|---------------------|-------------------------------------------------|
| 0      | 8    | `min_ts`            | Minimum timestamp in this block.                |
| 8      | 8    | `max_ts`            | Maximum timestamp in this block.                |
| 16     | 8    | `block_offset`      | Byte offset of the compressed block in the file.|
| 24     | 4    | `compressed_size`   | Size of the compressed block in bytes.          |
| 28     | 4    | `uncompressed_size` | Size of the uncompressed block in bytes.        |
| 32     | 4    | `record_count`      | Number of records in this block.                |
| 36     | 4    | `block_crc`         | CRC32C of the **uncompressed** block data.      |

The total block index size is `block_count * 40` bytes.

## 4. Footer

The footer occupies the last **32 bytes** of the file.

| Offset from EOF | Size | Field              | Description                                       |
|-----------------|------|--------------------|---------------------------------------------------|
| -32             | 8    | `index_offset`     | Byte offset of the block index in the file.       |
| -24             | 8    | `block_count`      | Number of block descriptors in the block index.   |
| -16             | 4    | `index_crc`        | CRC32C of the entire block index section.         |
| -12             | 4    | `footer_magic`     | ASCII `FLOG` (`0x46 0x4C 0x4F 0x47`), reversed `GOLF`. |
| -8              | 4    | `footer_crc`       | CRC32C of the preceding 24 bytes of the footer.   |
| -4              | 4    | `_padding`         | Reserved. Must be zero.                           |

## Reading Algorithm

### Opening a File

1. Read the last 32 bytes of the file (the footer).
2. Validate `footer_magic == "FLOG"`.
3. Validate `footer_crc` against bytes `[-32..-8]`.
4. Read `index_offset` and `block_count` from the footer.
5. Read `block_count * 40` bytes starting at `index_offset` (the block index).
6. Validate `index_crc` against the block index bytes.
7. Read the first 64 bytes (fixed header).
8. Validate `magic == "GOLF"` and `header_crc`.
9. If `metadata_length > 0`, read `metadata_length` bytes at offset 64.

### Range Query: `query(start_ts, end_ts)`

Given an inclusive range `[start_ts, end_ts]`:

1. **Find first block**: Binary search the block index for the first descriptor
   where `max_ts >= start_ts`.
2. **Find last block**: Binary search the block index for the last descriptor
   where `min_ts <= end_ts`.
3. If first > last, the range is empty.
4. For each block in `[first, last]`:
   a. Read `compressed_size` bytes from `block_offset`.
   b. Decompress if `compression != 0`.
   c. Validate `block_crc` against the uncompressed data.
   d. Parse records from the uncompressed bytes.
   e. For the first and last blocks, binary search within the decompressed
      records for the exact `start_ts`/`end_ts` boundaries.
   f. For middle blocks, all records are within range.
5. Return matching records.

### Point Query: `query(ts, ts)`

A point query is a range query where `start_ts == end_ts`.

## Writing Algorithm

### Append Phase

1. Create a writer with configuration: `record_value_size`, `ts_resolution`,
   `compression`, `block_capacity`, and optional metadata key-value pairs.
2. Append records as `(timestamp, value_bytes)` pairs. Records may be appended
   in any order.
3. The writer accumulates records in an internal buffer.

### Seal Phase

1. Sort all accumulated records by timestamp (ascending). Ties are permitted;
   their order is implementation-defined.
2. Partition the sorted records into blocks of up to `block_capacity` records.
   The last block may have fewer.
3. For each block:
   a. Serialize records into a flat byte array (uncompressed block layout).
   b. Compute `block_crc` (CRC32C of the uncompressed bytes).
   c. Compress the byte array per the chosen codec (or store raw if none).
   d. Record the block descriptor.
4. Write the file:
   a. Compute and write the fixed header (with min/max timestamps and record count).
   b. Write the variable metadata.
   c. Write all compressed data blocks sequentially.
   d. Write all block descriptors sequentially (the block index).
   e. Compute and write the footer.
5. The file is now complete and immutable.

## Versioning

The `version` field allows future evolution. Readers MUST reject files with a
version they do not support. Version 1 is defined by this document.

## Limits

- Maximum record value size: 2^32 - 1 bytes (4 GiB per record).
- Maximum records per block: 2^32 - 1.
- Maximum total records: 2^64 - 1.
- Maximum file size: limited by the operating system and filesystem.
- Maximum metadata size: 2^32 - 1 bytes.
