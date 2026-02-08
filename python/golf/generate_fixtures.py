#!/usr/bin/env python3
"""Generate cross-language test fixtures from Python."""

import sys
from pathlib import Path

from golf import (
    Compression,
    GolfWriter,
    MetadataEntry,
    TimestampResolution,
    WriterConfig,
)


def generate(output_dir: Path):
    output_dir.mkdir(parents=True, exist_ok=True)

    # py_small.golf: 20 records, no compression, value_size=8, block_capacity=4
    config = WriterConfig(
        record_value_size=8,
        ts_resolution=TimestampResolution.NANOSECONDS,
        compression=Compression.NONE,
        block_capacity=4,
    )
    w = GolfWriter(config)
    for i in range(20):
        val = bytearray(8)
        val[0] = i
        w.append(i * 1000, bytes(val))
    with open(output_dir / "py_small.golf", "wb") as f:
        w.seal(f)
    print("  py_small.golf: 20 records, no compression")

    # py_lz4.golf: 100 records, LZ4, value_size=16, block_capacity=8
    config = WriterConfig(
        record_value_size=16,
        ts_resolution=TimestampResolution.MICROSECONDS,
        compression=Compression.LZ4,
        block_capacity=8,
    )
    w = GolfWriter(config)
    for i in range(100):
        val = bytearray(16)
        val[0] = i & 0xFF
        val[1] = (i >> 8) & 0xFF
        w.append(i * 500, bytes(val))
    with open(output_dir / "py_lz4.golf", "wb") as f:
        w.seal(f)
    print("  py_lz4.golf: 100 records, LZ4")

    # py_metadata.golf: 10 records, with metadata
    config = WriterConfig(
        record_value_size=8,
        ts_resolution=TimestampResolution.NANOSECONDS,
        compression=Compression.NONE,
        block_capacity=4,
        metadata=[
            MetadataEntry(key="source", value="python-generator"),
            MetadataEntry(key="version", value="0.1.0"),
        ],
    )
    w = GolfWriter(config)
    for i in range(10):
        val = bytearray(8)
        val[0] = i
        w.append(i * 1000, bytes(val))
    with open(output_dir / "py_metadata.golf", "wb") as f:
        w.seal(f)
    print("  py_metadata.golf: 10 records, with metadata")


if __name__ == "__main__":
    output_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent.parent.parent / "testdata"
    generate(output_dir)
    print(f"Generated Python fixtures in {output_dir}")
