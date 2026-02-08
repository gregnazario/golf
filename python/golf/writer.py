"""GolfWriter: append records, then seal into an immutable .golf file."""

from dataclasses import dataclass, field
from typing import BinaryIO, List, Optional

from golf.core import (
    FIXED_HEADER_SIZE,
    FORMAT_VERSION,
    BlockDescriptor,
    Compression,
    Footer,
    Header,
    MetadataEntry,
    Record,
    TimestampResolution,
    compress_block,
    compute_crc32c,
    encode_metadata,
    serialize_block,
)


@dataclass
class WriterConfig:
    record_value_size: int = 64
    ts_resolution: TimestampResolution = TimestampResolution.NANOSECONDS
    compression: Compression = Compression.LZ4
    block_capacity: int = 8192
    metadata: List[MetadataEntry] = field(default_factory=list)


class GolfWriter:
    """Accumulates records and seals them into a .golf file."""

    def __init__(self, config: WriterConfig):
        self.config = config
        self._records: List[Record] = []
        self._sealed = False

    def append(self, timestamp: int, value: bytes) -> None:
        """Append a record. Value must be exactly record_value_size bytes."""
        if self._sealed:
            raise RuntimeError("writer already sealed")
        if len(value) != self.config.record_value_size:
            raise ValueError(
                f"value size mismatch: expected {self.config.record_value_size}, "
                f"got {len(value)}"
            )
        self._records.append(Record(timestamp=timestamp, value=bytes(value)))

    def __len__(self) -> int:
        return len(self._records)

    def seal(self, dest: BinaryIO) -> None:
        """Sort, compress, and write the .golf file."""
        if self._sealed:
            raise RuntimeError("writer already sealed")
        if not self._records:
            raise RuntimeError("no records to seal")
        self._sealed = True

        # Sort by timestamp
        self._records.sort(key=lambda r: r.timestamp)

        record_value_size = self.config.record_value_size
        block_capacity = self.config.block_capacity

        meta_bytes = encode_metadata(self.config.metadata)
        min_ts = self._records[0].timestamp
        max_ts = self._records[-1].timestamp

        header = Header(
            version=FORMAT_VERSION,
            flags=0,
            record_value_size=record_value_size,
            ts_resolution=self.config.ts_resolution,
            compression=self.config.compression,
            block_capacity=block_capacity,
            min_timestamp=min_ts,
            max_timestamp=max_ts,
            record_count=len(self._records),
            metadata_length=len(meta_bytes),
        )

        # Write header
        dest.write(header.encode())
        if meta_bytes:
            dest.write(meta_bytes)

        offset = FIXED_HEADER_SIZE + len(meta_bytes)

        # Build and write blocks
        descriptors: List[BlockDescriptor] = []
        for i in range(0, len(self._records), block_capacity):
            chunk = self._records[i : i + block_capacity]

            raw = serialize_block(chunk, record_value_size)
            block_crc = compute_crc32c(raw)
            uncompressed_size = len(raw)

            compressed = compress_block(raw, self.config.compression)
            compressed_size = len(compressed)

            descriptors.append(
                BlockDescriptor(
                    min_ts=chunk[0].timestamp,
                    max_ts=chunk[-1].timestamp,
                    block_offset=offset,
                    compressed_size=compressed_size,
                    uncompressed_size=uncompressed_size,
                    record_count=len(chunk),
                    block_crc=block_crc,
                )
            )

            dest.write(compressed)
            offset += compressed_size

        # Write block index
        index_offset = offset
        index_parts = [d.encode_bytes() for d in descriptors]
        index_bytes = b"".join(index_parts)
        index_crc = compute_crc32c(index_bytes)
        dest.write(index_bytes)

        # Write footer
        footer = Footer(
            index_offset=index_offset,
            block_count=len(descriptors),
            index_crc=index_crc,
        )
        dest.write(footer.encode())
