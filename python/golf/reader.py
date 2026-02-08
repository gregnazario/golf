"""GolfReader: read-only access to .golf files with range query support."""

import mmap
import struct
from pathlib import Path
from typing import BinaryIO, List, Optional, Union

from golf.core import (
    BLOCK_DESCRIPTOR_SIZE,
    FIXED_HEADER_SIZE,
    FOOTER_SIZE,
    BlockDescriptor,
    Footer,
    Header,
    Record,
    compute_crc32c,
    decode_metadata,
    decompress_block,
    find_first_block,
    find_last_block,
    MetadataEntry,
)


def _binary_search_first(data: bytes, record_size: int, count: int, target: int) -> int:
    """Find first record index where timestamp >= target."""
    lo, hi = 0, count
    while lo < hi:
        mid = lo + (hi - lo) // 2
        ts = struct.unpack_from("<Q", data, mid * record_size)[0]
        if ts < target:
            lo = mid + 1
        else:
            hi = mid
    return lo


def _binary_search_last(data: bytes, record_size: int, count: int, target: int) -> int:
    """Find last record index where timestamp <= target."""
    lo, hi = 0, count
    while lo < hi:
        mid = lo + (hi - lo) // 2
        ts = struct.unpack_from("<Q", data, mid * record_size)[0]
        if ts <= target:
            lo = mid + 1
        else:
            hi = mid
    return max(0, lo - 1)


def _collect_range(
    descriptors: List[BlockDescriptor],
    compression,
    record_value_size: int,
    start_ts: int,
    end_ts: int,
    read_block,
) -> List[Record]:
    """Shared range query logic."""
    first_idx = find_first_block(descriptors, start_ts)
    if first_idx < 0:
        return []
    last_idx = find_last_block(descriptors, end_ts)
    if last_idx < 0:
        return []
    if first_idx > last_idx:
        return []

    record_size = 8 + record_value_size
    results = []

    for bi in range(first_idx, last_idx + 1):
        desc = descriptors[bi]
        compressed = read_block(desc)

        raw = decompress_block(compressed, compression, desc.uncompressed_size)

        actual_crc = compute_crc32c(raw)
        if actual_crc != desc.block_crc:
            raise ValueError(
                f"block CRC mismatch: expected {desc.block_crc:#010x}, "
                f"got {actual_crc:#010x}"
            )

        count = desc.record_count
        rec_start = 0
        rec_end = count - 1

        if bi == first_idx:
            rec_start = _binary_search_first(raw, record_size, count, start_ts)
        if bi == last_idx:
            rec_end = _binary_search_last(raw, record_size, count, end_ts)

        if rec_start <= rec_end < count:
            for i in range(rec_start, rec_end + 1):
                off = i * record_size
                ts = struct.unpack_from("<Q", raw, off)[0]
                if start_ts <= ts <= end_ts:
                    val = raw[off + 8 : off + record_size]
                    results.append(Record(timestamp=ts, value=bytes(val)))

    return results


class GolfReader:
    """Reads .golf files using standard I/O (read + seek)."""

    def __init__(self, f: BinaryIO):
        self._f = f

        # Get file size
        f.seek(0, 2)
        file_size = f.tell()
        if file_size < FIXED_HEADER_SIZE + FOOTER_SIZE:
            raise ValueError(f"file too small: {file_size} bytes")

        # Read footer
        f.seek(-FOOTER_SIZE, 2)
        footer_buf = f.read(FOOTER_SIZE)
        footer = Footer.decode(footer_buf)

        # Read block index
        index_size = footer.block_count * BLOCK_DESCRIPTOR_SIZE
        f.seek(footer.index_offset)
        index_buf = f.read(index_size)
        actual_crc = compute_crc32c(index_buf)
        if actual_crc != footer.index_crc:
            raise ValueError("block index CRC mismatch")

        self.descriptors: List[BlockDescriptor] = []
        for i in range(footer.block_count):
            start = i * BLOCK_DESCRIPTOR_SIZE
            chunk = index_buf[start : start + BLOCK_DESCRIPTOR_SIZE]
            self.descriptors.append(BlockDescriptor.decode(chunk))

        # Read header
        f.seek(0)
        header_buf = f.read(FIXED_HEADER_SIZE)
        self.header = Header.decode(header_buf)

        # Read metadata
        self.metadata: List[MetadataEntry] = []
        if self.header.metadata_length > 0:
            meta_buf = f.read(self.header.metadata_length)
            self.metadata = decode_metadata(meta_buf)

    @classmethod
    def open(cls, path: Union[str, Path]) -> "GolfReader":
        """Open a golf file by path."""
        f = open(path, "rb")
        return cls(f)

    @property
    def record_count(self) -> int:
        return self.header.record_count

    @property
    def timestamp_range(self):
        return (self.header.min_timestamp, self.header.max_timestamp)

    def query(self, start_ts: int, end_ts: int) -> List[Record]:
        """Query records in the inclusive range [start_ts, end_ts]."""

        def read_block(desc: BlockDescriptor) -> bytes:
            self._f.seek(desc.block_offset)
            return self._f.read(desc.compressed_size)

        return _collect_range(
            self.descriptors,
            self.header.compression,
            self.header.record_value_size,
            start_ts,
            end_ts,
            read_block,
        )

    def close(self):
        self._f.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class MmapGolfReader:
    """Reads .golf files using memory-mapped I/O."""

    def __init__(self, path: Union[str, Path]):
        self._file = open(path, "rb")
        self._mmap = mmap.mmap(self._file.fileno(), 0, access=mmap.ACCESS_READ)
        data = self._mmap

        size = len(data)
        if size < FIXED_HEADER_SIZE + FOOTER_SIZE:
            raise ValueError(f"file too small: {size} bytes")

        # Parse footer
        footer_buf = data[size - FOOTER_SIZE : size]
        footer = Footer.decode(bytes(footer_buf))

        # Parse block index
        idx_start = footer.index_offset
        idx_end = idx_start + footer.block_count * BLOCK_DESCRIPTOR_SIZE
        index_buf = bytes(data[idx_start:idx_end])
        actual_crc = compute_crc32c(index_buf)
        if actual_crc != footer.index_crc:
            raise ValueError("block index CRC mismatch")

        self.descriptors: List[BlockDescriptor] = []
        for i in range(footer.block_count):
            start = i * BLOCK_DESCRIPTOR_SIZE
            chunk = index_buf[start : start + BLOCK_DESCRIPTOR_SIZE]
            self.descriptors.append(BlockDescriptor.decode(chunk))

        # Parse header
        header_buf = bytes(data[0:FIXED_HEADER_SIZE])
        self.header = Header.decode(header_buf)

        # Parse metadata
        self.metadata: List[MetadataEntry] = []
        if self.header.metadata_length > 0:
            meta_buf = bytes(
                data[FIXED_HEADER_SIZE : FIXED_HEADER_SIZE + self.header.metadata_length]
            )
            self.metadata = decode_metadata(meta_buf)

    @property
    def record_count(self) -> int:
        return self.header.record_count

    @property
    def timestamp_range(self):
        return (self.header.min_timestamp, self.header.max_timestamp)

    def query(self, start_ts: int, end_ts: int) -> List[Record]:
        """Query records in the inclusive range [start_ts, end_ts]."""
        data = self._mmap

        def read_block(desc: BlockDescriptor) -> bytes:
            return bytes(data[desc.block_offset : desc.block_offset + desc.compressed_size])

        return _collect_range(
            self.descriptors,
            self.header.compression,
            self.header.record_value_size,
            start_ts,
            end_ts,
            read_block,
        )

    def close(self):
        self._mmap.close()
        self._file.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
