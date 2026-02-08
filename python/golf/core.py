"""Core data types and encoding/decoding for the golf file format."""

import struct
from dataclasses import dataclass, field
from enum import IntEnum
from typing import List, Tuple

import crc32c as _crc32c

# Constants
FIXED_HEADER_SIZE = 64
BLOCK_DESCRIPTOR_SIZE = 40
FOOTER_SIZE = 32
FORMAT_VERSION = 1
HEADER_MAGIC = b"GOLF"
FOOTER_MAGIC = b"FLOG"


def compute_crc32c(data: bytes) -> int:
    """Compute CRC-32C (Castagnoli) checksum."""
    return _crc32c.crc32c(data)


class TimestampResolution(IntEnum):
    NANOSECONDS = 0
    MICROSECONDS = 1
    MILLISECONDS = 2


class Compression(IntEnum):
    NONE = 0
    LZ4 = 1
    ZSTD = 2


@dataclass
class Header:
    version: int = FORMAT_VERSION
    flags: int = 0
    record_value_size: int = 0
    ts_resolution: TimestampResolution = TimestampResolution.NANOSECONDS
    compression: Compression = Compression.NONE
    block_capacity: int = 8192
    min_timestamp: int = 0
    max_timestamp: int = 0
    record_count: int = 0
    metadata_length: int = 0

    def encode(self) -> bytes:
        """Encode the fixed header to exactly 64 bytes."""
        buf = bytearray(FIXED_HEADER_SIZE)
        buf[0:4] = HEADER_MAGIC
        struct.pack_into("<H", buf, 4, self.version)
        struct.pack_into("<H", buf, 6, self.flags)
        struct.pack_into("<I", buf, 8, self.record_value_size)
        buf[12] = self.ts_resolution
        buf[13] = self.compression
        struct.pack_into("<I", buf, 14, self.block_capacity)
        # 18..28 reserved (zeros)
        struct.pack_into("<Q", buf, 28, self.min_timestamp)
        struct.pack_into("<Q", buf, 36, self.max_timestamp)
        struct.pack_into("<Q", buf, 44, self.record_count)
        struct.pack_into("<I", buf, 52, self.metadata_length)
        crc = compute_crc32c(bytes(buf[0:56]))
        struct.pack_into("<I", buf, 56, crc)
        # 60..64 padding (zeros)
        return bytes(buf)

    @classmethod
    def decode(cls, buf: bytes) -> "Header":
        """Decode a fixed header from exactly 64 bytes."""
        if len(buf) != FIXED_HEADER_SIZE:
            raise ValueError(f"expected {FIXED_HEADER_SIZE} bytes, got {len(buf)}")
        if buf[0:4] != HEADER_MAGIC:
            raise ValueError("invalid header magic")
        version = struct.unpack_from("<H", buf, 4)[0]
        if version != FORMAT_VERSION:
            raise ValueError(f"unsupported version: {version}")

        stored_crc = struct.unpack_from("<I", buf, 56)[0]
        computed_crc = compute_crc32c(buf[0:56])
        if stored_crc != computed_crc:
            raise ValueError(
                f"header CRC mismatch: expected {computed_crc:#010x}, got {stored_crc:#010x}"
            )

        return cls(
            version=version,
            flags=struct.unpack_from("<H", buf, 6)[0],
            record_value_size=struct.unpack_from("<I", buf, 8)[0],
            ts_resolution=TimestampResolution(buf[12]),
            compression=Compression(buf[13]),
            block_capacity=struct.unpack_from("<I", buf, 14)[0],
            min_timestamp=struct.unpack_from("<Q", buf, 28)[0],
            max_timestamp=struct.unpack_from("<Q", buf, 36)[0],
            record_count=struct.unpack_from("<Q", buf, 44)[0],
            metadata_length=struct.unpack_from("<I", buf, 52)[0],
        )


@dataclass
class MetadataEntry:
    key: str
    value: str


@dataclass
class BlockDescriptor:
    min_ts: int = 0
    max_ts: int = 0
    block_offset: int = 0
    compressed_size: int = 0
    uncompressed_size: int = 0
    record_count: int = 0
    block_crc: int = 0

    def encode(self) -> bytes:
        """Encode to 40 bytes."""
        return struct.pack(
            "<QQQIIIII",
            self.min_ts,
            self.max_ts,
            self.block_offset,
            self.compressed_size,
            self.uncompressed_size,
            self.record_count,
            self.block_crc,
            0,  # padding to avoid struct issues
        )[:BLOCK_DESCRIPTOR_SIZE]

    def encode_bytes(self) -> bytes:
        buf = bytearray(BLOCK_DESCRIPTOR_SIZE)
        struct.pack_into("<Q", buf, 0, self.min_ts)
        struct.pack_into("<Q", buf, 8, self.max_ts)
        struct.pack_into("<Q", buf, 16, self.block_offset)
        struct.pack_into("<I", buf, 24, self.compressed_size)
        struct.pack_into("<I", buf, 28, self.uncompressed_size)
        struct.pack_into("<I", buf, 32, self.record_count)
        struct.pack_into("<I", buf, 36, self.block_crc)
        return bytes(buf)

    @classmethod
    def decode(cls, buf: bytes) -> "BlockDescriptor":
        """Decode from 40 bytes."""
        if len(buf) < BLOCK_DESCRIPTOR_SIZE:
            raise ValueError(f"expected {BLOCK_DESCRIPTOR_SIZE} bytes")
        return cls(
            min_ts=struct.unpack_from("<Q", buf, 0)[0],
            max_ts=struct.unpack_from("<Q", buf, 8)[0],
            block_offset=struct.unpack_from("<Q", buf, 16)[0],
            compressed_size=struct.unpack_from("<I", buf, 24)[0],
            uncompressed_size=struct.unpack_from("<I", buf, 28)[0],
            record_count=struct.unpack_from("<I", buf, 32)[0],
            block_crc=struct.unpack_from("<I", buf, 36)[0],
        )


@dataclass
class Record:
    timestamp: int
    value: bytes


@dataclass
class Footer:
    index_offset: int = 0
    block_count: int = 0
    index_crc: int = 0

    def encode(self) -> bytes:
        buf = bytearray(FOOTER_SIZE)
        struct.pack_into("<Q", buf, 0, self.index_offset)
        struct.pack_into("<Q", buf, 8, self.block_count)
        struct.pack_into("<I", buf, 16, self.index_crc)
        buf[20:24] = FOOTER_MAGIC
        crc = compute_crc32c(bytes(buf[0:24]))
        struct.pack_into("<I", buf, 24, crc)
        # 28..32 padding (zeros)
        return bytes(buf)

    @classmethod
    def decode(cls, buf: bytes) -> "Footer":
        if len(buf) != FOOTER_SIZE:
            raise ValueError(f"expected {FOOTER_SIZE} bytes, got {len(buf)}")
        if buf[20:24] != FOOTER_MAGIC:
            raise ValueError("invalid footer magic")
        stored_crc = struct.unpack_from("<I", buf, 24)[0]
        computed_crc = compute_crc32c(buf[0:24])
        if stored_crc != computed_crc:
            raise ValueError(
                f"footer CRC mismatch: expected {computed_crc:#010x}, got {stored_crc:#010x}"
            )
        return cls(
            index_offset=struct.unpack_from("<Q", buf, 0)[0],
            block_count=struct.unpack_from("<Q", buf, 8)[0],
            index_crc=struct.unpack_from("<I", buf, 16)[0],
        )


def encode_metadata(entries: List[MetadataEntry]) -> bytes:
    """Encode metadata entries to bytes."""
    parts = []
    for e in entries:
        kb = e.key.encode("utf-8")
        vb = e.value.encode("utf-8")
        parts.append(struct.pack("<H", len(kb)))
        parts.append(kb)
        parts.append(struct.pack("<H", len(vb)))
        parts.append(vb)
    return b"".join(parts)


def decode_metadata(data: bytes) -> List[MetadataEntry]:
    """Decode metadata entries from bytes."""
    entries = []
    offset = 0
    while offset < len(data):
        if offset + 2 > len(data):
            raise ValueError("truncated metadata key length")
        key_len = struct.unpack_from("<H", data, offset)[0]
        offset += 2
        if offset + key_len > len(data):
            raise ValueError("truncated metadata key")
        key = data[offset : offset + key_len].decode("utf-8")
        offset += key_len

        if offset + 2 > len(data):
            raise ValueError("truncated metadata value length")
        val_len = struct.unpack_from("<H", data, offset)[0]
        offset += 2
        if offset + val_len > len(data):
            raise ValueError("truncated metadata value")
        value = data[offset : offset + val_len].decode("utf-8")
        offset += val_len

        entries.append(MetadataEntry(key=key, value=value))
    return entries


def compress_block(data: bytes, codec: Compression) -> bytes:
    """Compress a block.

    LZ4 uses the lz4_flex prepend-size format: [4 bytes LE uncompressed size][LZ4 block data].
    """
    if codec == Compression.NONE:
        return data
    elif codec == Compression.LZ4:
        import lz4.block

        # Compress without stored size (raw LZ4 block)
        compressed = lz4.block.compress(data, store_size=False)
        # Prepend uncompressed size as LE u32 (matching Rust lz4_flex::compress_prepend_size)
        return struct.pack("<I", len(data)) + compressed
    elif codec == Compression.ZSTD:
        import zstandard

        cctx = zstandard.ZstdCompressor(level=3)
        return cctx.compress(data)
    else:
        raise ValueError(f"unsupported compression: {codec}")


def decompress_block(data: bytes, codec: Compression, uncompressed_size: int) -> bytes:
    """Decompress a block.

    LZ4 expects the lz4_flex prepend-size format: [4 bytes LE uncompressed size][LZ4 block data].
    """
    if codec == Compression.NONE:
        return data
    elif codec == Compression.LZ4:
        import lz4.block

        # Skip the 4-byte LE size prefix (matching Rust lz4_flex::decompress_size_prepended)
        if len(data) < 4:
            raise ValueError("LZ4 data too short")
        orig_size = struct.unpack_from("<I", data, 0)[0]
        return lz4.block.decompress(data[4:], uncompressed_size=orig_size)
    elif codec == Compression.ZSTD:
        import zstandard

        dctx = zstandard.ZstdDecompressor()
        return dctx.decompress(data, max_output_size=uncompressed_size)
    else:
        raise ValueError(f"unsupported compression: {codec}")


def serialize_block(records: List[Record], record_value_size: int) -> bytes:
    """Serialize records into a flat block buffer."""
    parts = []
    for r in records:
        parts.append(struct.pack("<Q", r.timestamp))
        val = r.value
        if len(val) < record_value_size:
            val = val + b"\x00" * (record_value_size - len(val))
        parts.append(val[:record_value_size])
    return b"".join(parts)


def parse_records(data: bytes, record_value_size: int) -> List[Record]:
    """Parse records from an uncompressed block buffer."""
    record_size = 8 + record_value_size
    count = len(data) // record_size
    records = []
    for i in range(count):
        off = i * record_size
        ts = struct.unpack_from("<Q", data, off)[0]
        val = data[off + 8 : off + record_size]
        records.append(Record(timestamp=ts, value=bytes(val)))
    return records


def find_first_block(descriptors: List[BlockDescriptor], target: int) -> int:
    """Binary search for first block where max_ts >= target. Returns -1 if none."""
    lo, hi = 0, len(descriptors)
    while lo < hi:
        mid = lo + (hi - lo) // 2
        if descriptors[mid].max_ts < target:
            lo = mid + 1
        else:
            hi = mid
    return lo if lo < len(descriptors) else -1


def find_last_block(descriptors: List[BlockDescriptor], target: int) -> int:
    """Binary search for last block where min_ts <= target. Returns -1 if none."""
    lo, hi = 0, len(descriptors)
    while lo < hi:
        mid = lo + (hi - lo) // 2
        if descriptors[mid].min_ts <= target:
            lo = mid + 1
        else:
            hi = mid
    return lo - 1 if lo > 0 else -1
