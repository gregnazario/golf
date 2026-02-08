"""Tests for the golf Python implementation."""

import io
import os
import tempfile
from pathlib import Path

import pytest

from golf import (
    Compression,
    GolfReader,
    GolfWriter,
    MetadataEntry,
    MmapGolfReader,
    TimestampResolution,
    WriterConfig,
)

TESTDATA_DIR = Path(__file__).parent.parent.parent / "testdata"


def build_in_memory(records, config):
    w = GolfWriter(config)
    for ts, val in records:
        w.append(ts, val)
    buf = io.BytesIO()
    w.seal(buf)
    buf.seek(0)
    return buf


def make_value(seed, size):
    return bytes((seed + i) & 0xFF for i in range(size))


class TestRoundtrip:
    def test_no_compression(self):
        config = WriterConfig(
            record_value_size=16,
            compression=Compression.NONE,
            block_capacity=4,
        )
        records = [(i * 1000, make_value(i, 16)) for i in range(10)]
        buf = build_in_memory(records, config)

        reader = GolfReader(buf)
        assert reader.record_count == 10
        assert reader.timestamp_range == (0, 9000)

        result = reader.query(0, 9000)
        assert len(result) == 10
        for i, rec in enumerate(result):
            assert rec.timestamp == i * 1000
            assert rec.value == make_value(i, 16)

    def test_lz4(self):
        config = WriterConfig(
            record_value_size=32,
            compression=Compression.LZ4,
            block_capacity=8,
            ts_resolution=TimestampResolution.MICROSECONDS,
        )
        records = [(i * 500, make_value(i, 32)) for i in range(100)]
        buf = build_in_memory(records, config)

        reader = GolfReader(buf)
        assert reader.record_count == 100

        result = reader.query(5000, 10000)
        timestamps = [r.timestamp for r in result]
        expected = [i * 500 for i in range(10, 21)]
        assert timestamps == expected

    def test_zstd(self):
        config = WriterConfig(
            record_value_size=8,
            compression=Compression.ZSTD,
            block_capacity=16,
            ts_resolution=TimestampResolution.MILLISECONDS,
        )
        records = [(i * 100, bytes([i & 0xFF] * 8)) for i in range(50)]
        buf = build_in_memory(records, config)

        reader = GolfReader(buf)
        assert reader.record_count == 50

        result = reader.query(2500, 2500)
        assert len(result) == 1
        assert result[0].timestamp == 2500


class TestEdgeCases:
    def test_empty_range(self):
        config = WriterConfig(
            record_value_size=8,
            compression=Compression.NONE,
            block_capacity=4,
        )
        records = [(i * 100, bytes(8)) for i in range(10)]
        buf = build_in_memory(records, config)
        reader = GolfReader(buf)

        # After all records
        assert reader.query(1000, 2000) == []

        # In gap
        assert reader.query(50, 99) == []

    def test_full_range(self):
        config = WriterConfig(
            record_value_size=8,
            compression=Compression.LZ4,
            block_capacity=4,
        )
        records = [(i * 10, bytes([i & 0xFF] * 8)) for i in range(20)]
        buf = build_in_memory(records, config)
        reader = GolfReader(buf)

        result = reader.query(0, 2**64 - 1)
        assert len(result) == 20

    def test_unsorted_input(self):
        config = WriterConfig(
            record_value_size=4,
            compression=Compression.NONE,
            block_capacity=4,
        )
        w = GolfWriter(config)
        for ts, v in [(300, 3), (100, 1), (200, 2), (500, 5), (400, 4)]:
            w.append(ts, bytes([v, 0, 0, 0]))

        buf = io.BytesIO()
        w.seal(buf)
        buf.seek(0)
        reader = GolfReader(buf)

        result = reader.query(0, 600)
        timestamps = [r.timestamp for r in result]
        assert timestamps == [100, 200, 300, 400, 500]

    def test_duplicate_timestamps(self):
        config = WriterConfig(
            record_value_size=4,
            compression=Compression.NONE,
            block_capacity=4,
        )
        w = GolfWriter(config)
        for i in range(5):
            w.append(100, bytes([i, 0, 0, 0]))
        w.append(200, bytes([5, 0, 0, 0]))

        buf = io.BytesIO()
        w.seal(buf)
        buf.seek(0)
        reader = GolfReader(buf)

        result = reader.query(100, 100)
        assert len(result) == 5

        result = reader.query(100, 200)
        assert len(result) == 6


class TestMetadata:
    def test_roundtrip(self):
        config = WriterConfig(
            record_value_size=8,
            compression=Compression.NONE,
            block_capacity=4,
            metadata=[
                MetadataEntry(key="source", value="test-suite"),
                MetadataEntry(key="version", value="1.0.0"),
            ],
        )
        records = [(i * 100, bytes(8)) for i in range(5)]
        buf = build_in_memory(records, config)
        reader = GolfReader(buf)

        assert len(reader.metadata) == 2
        assert reader.metadata[0].key == "source"
        assert reader.metadata[0].value == "test-suite"


class TestMmapReader:
    def test_basic(self):
        config = WriterConfig(
            record_value_size=16,
            compression=Compression.LZ4,
            block_capacity=8,
        )
        records = [(i * 100, make_value(i, 16)) for i in range(50)]

        with tempfile.NamedTemporaryFile(suffix=".golf", delete=False) as tmp:
            w = GolfWriter(config)
            for ts, val in records:
                w.append(ts, val)
            w.seal(tmp)
            tmp_path = tmp.name

        try:
            with MmapGolfReader(tmp_path) as reader:
                assert reader.record_count == 50
                result = reader.query(1000, 2000)
                timestamps = [r.timestamp for r in result]
                expected = [i * 100 for i in range(10, 21)]
                assert timestamps == expected
        finally:
            os.unlink(tmp_path)


class TestCrossLanguageFixtures:
    @pytest.fixture
    def has_fixtures(self):
        if not TESTDATA_DIR.exists():
            pytest.skip("testdata not found")

    def test_read_small(self, has_fixtures):
        with GolfReader.open(TESTDATA_DIR / "small.golf") as reader:
            assert reader.record_count == 20
            assert reader.header.record_value_size == 8

            result = reader.query(0, 19000)
            assert len(result) == 20
            assert result[0].timestamp == 0
            assert result[0].value[0] == 0
            assert result[-1].timestamp == 19000
            assert result[-1].value[0] == 19

    def test_read_with_metadata(self, has_fixtures):
        with GolfReader.open(TESTDATA_DIR / "with_metadata.golf") as reader:
            assert len(reader.metadata) == 2
            assert reader.metadata[0].key == "source"
            assert reader.metadata[0].value == "fixture-generator"

    def test_read_lz4(self, has_fixtures):
        with GolfReader.open(TESTDATA_DIR / "compressed_lz4.golf") as reader:
            assert reader.record_count == 100
            result = reader.query(0, 49500)
            assert len(result) == 100

    def test_read_zstd(self, has_fixtures):
        with GolfReader.open(TESTDATA_DIR / "compressed_zstd.golf") as reader:
            assert reader.record_count == 100
            result = reader.query(0, 49500)
            assert len(result) == 100

    # Cross-language: Go fixtures
    def test_read_go_small(self, has_fixtures):
        p = TESTDATA_DIR / "go_small.golf"
        if not p.exists():
            pytest.skip("go_small.golf not found")
        with GolfReader.open(p) as reader:
            assert reader.record_count == 20
            result = reader.query(0, 19000)
            assert len(result) == 20
            assert result[0].value[0] == 0
            assert result[-1].value[0] == 19

    def test_read_go_lz4(self, has_fixtures):
        p = TESTDATA_DIR / "go_lz4.golf"
        if not p.exists():
            pytest.skip("go_lz4.golf not found")
        with GolfReader.open(p) as reader:
            assert reader.record_count == 100
            result = reader.query(0, 49500)
            assert len(result) == 100

    def test_read_go_metadata(self, has_fixtures):
        p = TESTDATA_DIR / "go_metadata.golf"
        if not p.exists():
            pytest.skip("go_metadata.golf not found")
        with GolfReader.open(p) as reader:
            assert reader.metadata[0].key == "source"
            assert reader.metadata[0].value == "go-generator"

    # Cross-language: TypeScript fixtures
    def test_read_ts_small(self, has_fixtures):
        p = TESTDATA_DIR / "ts_small.golf"
        if not p.exists():
            pytest.skip("ts_small.golf not found")
        with GolfReader.open(p) as reader:
            assert reader.record_count == 20
            result = reader.query(0, 19000)
            assert len(result) == 20

    def test_read_ts_lz4(self, has_fixtures):
        p = TESTDATA_DIR / "ts_lz4.golf"
        if not p.exists():
            pytest.skip("ts_lz4.golf not found")
        with GolfReader.open(p) as reader:
            assert reader.record_count == 100
            result = reader.query(0, 49500)
            assert len(result) == 100

    def test_read_ts_metadata(self, has_fixtures):
        p = TESTDATA_DIR / "ts_metadata.golf"
        if not p.exists():
            pytest.skip("ts_metadata.golf not found")
        with GolfReader.open(p) as reader:
            assert reader.metadata[0].key == "source"
            assert reader.metadata[0].value == "typescript-generator"
