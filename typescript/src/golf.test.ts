import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { GolfWriter, type WriterConfig } from './writer.js';
import { GolfReader } from './reader.js';
import { Compression, TimestampResolution, type Record } from './core.js';

const TESTDATA_DIR = path.join(__dirname, '..', '..', 'testdata');

function makeValue(seed: number, size: number): Buffer {
  const buf = Buffer.alloc(size);
  for (let i = 0; i < size; i++) {
    buf[i] = (seed + i) & 0xff;
  }
  return buf;
}

function buildInMemory(
  records: Array<[bigint, Buffer]>,
  config: WriterConfig,
): Buffer {
  const w = new GolfWriter(config);
  for (const [ts, val] of records) {
    w.append(ts, val);
  }
  return w.seal();
}

describe('Roundtrip', () => {
  test('no compression', () => {
    const records: Array<[bigint, Buffer]> = Array.from({ length: 10 }, (_, i) => [
      BigInt(i) * 1000n,
      makeValue(i, 16),
    ]);
    const data = buildInMemory(records, {
      recordValueSize: 16,
      compression: Compression.None,
      blockCapacity: 4,
    });

    const reader = GolfReader.fromBuffer(data);
    assert.equal(reader.recordCount, 10n);
    assert.deepEqual(reader.timestampRange, [0n, 9000n]);

    const result = reader.query(0n, 9000n);
    assert.equal(result.length, 10);
    for (let i = 0; i < result.length; i++) {
      assert.equal(result[i].timestamp, BigInt(i) * 1000n);
      assert.deepEqual(result[i].value, makeValue(i, 16));
    }
  });

  test('LZ4', () => {
    const records: Array<[bigint, Buffer]> = Array.from({ length: 100 }, (_, i) => [
      BigInt(i) * 500n,
      makeValue(i, 32),
    ]);
    const data = buildInMemory(records, {
      recordValueSize: 32,
      compression: Compression.Lz4,
      blockCapacity: 8,
      tsResolution: TimestampResolution.Microseconds,
    });

    const reader = GolfReader.fromBuffer(data);
    assert.equal(reader.recordCount, 100n);

    const result = reader.query(5000n, 10000n);
    const timestamps = result.map(r => r.timestamp);
    const expected = Array.from({ length: 11 }, (_, i) => BigInt(i + 10) * 500n);
    assert.deepEqual(timestamps, expected);
  });
});

describe('Edge cases', () => {
  test('empty range', () => {
    const records: Array<[bigint, Buffer]> = Array.from({ length: 10 }, (_, i) => [
      BigInt(i) * 100n,
      Buffer.alloc(8),
    ]);
    const data = buildInMemory(records, {
      recordValueSize: 8,
      compression: Compression.None,
      blockCapacity: 4,
    });
    const reader = GolfReader.fromBuffer(data);

    // After all records
    assert.equal(reader.query(1000n, 2000n).length, 0);

    // In gap
    assert.equal(reader.query(50n, 99n).length, 0);
  });

  test('full range', () => {
    const records: Array<[bigint, Buffer]> = Array.from({ length: 20 }, (_, i) => [
      BigInt(i) * 10n,
      Buffer.alloc(8, i & 0xff),
    ]);
    const data = buildInMemory(records, {
      recordValueSize: 8,
      compression: Compression.Lz4,
      blockCapacity: 4,
    });
    const reader = GolfReader.fromBuffer(data);

    const result = reader.query(0n, 0xffffffffffffffffn);
    assert.equal(result.length, 20);
  });

  test('unsorted input', () => {
    const w = new GolfWriter({
      recordValueSize: 4,
      compression: Compression.None,
      blockCapacity: 4,
    });
    const pairs: Array<[bigint, number]> = [
      [300n, 3], [100n, 1], [200n, 2], [500n, 5], [400n, 4],
    ];
    for (const [ts, v] of pairs) {
      w.append(ts, Buffer.from([v, 0, 0, 0]));
    }
    const data = w.seal();
    const reader = GolfReader.fromBuffer(data);

    const result = reader.query(0n, 600n);
    const timestamps = result.map(r => r.timestamp);
    assert.deepEqual(timestamps, [100n, 200n, 300n, 400n, 500n]);
  });

  test('duplicate timestamps', () => {
    const w = new GolfWriter({
      recordValueSize: 4,
      compression: Compression.None,
      blockCapacity: 4,
    });
    for (let i = 0; i < 5; i++) {
      w.append(100n, Buffer.from([i, 0, 0, 0]));
    }
    w.append(200n, Buffer.from([5, 0, 0, 0]));
    const data = w.seal();
    const reader = GolfReader.fromBuffer(data);

    assert.equal(reader.query(100n, 100n).length, 5);
    assert.equal(reader.query(100n, 200n).length, 6);
  });
});

describe('Metadata', () => {
  test('roundtrip', () => {
    const data = buildInMemory(
      Array.from({ length: 5 }, (_, i) => [BigInt(i) * 100n, Buffer.alloc(8)] as [bigint, Buffer]),
      {
        recordValueSize: 8,
        compression: Compression.None,
        blockCapacity: 4,
        metadata: [
          { key: 'source', value: 'test-suite' },
          { key: 'version', value: '1.0.0' },
        ],
      },
    );
    const reader = GolfReader.fromBuffer(data);
    assert.equal(reader.metadata.length, 2);
    assert.equal(reader.metadata[0].key, 'source');
    assert.equal(reader.metadata[0].value, 'test-suite');
  });
});

describe('Cross-language fixtures', () => {
  const fixtureExists = fs.existsSync(TESTDATA_DIR);

  test('read small.golf', { skip: !fixtureExists }, () => {
    const reader = GolfReader.open(path.join(TESTDATA_DIR, 'small.golf'));
    assert.equal(reader.recordCount, 20n);
    assert.equal(reader.header.recordValueSize, 8);

    const result = reader.query(0n, 19000n);
    assert.equal(result.length, 20);
    assert.equal(result[0].timestamp, 0n);
    assert.equal(result[0].value[0], 0);
    assert.equal(result[result.length - 1].timestamp, 19000n);
    assert.equal(result[result.length - 1].value[0], 19);
  });

  test('read with_metadata.golf', { skip: !fixtureExists }, () => {
    const reader = GolfReader.open(path.join(TESTDATA_DIR, 'with_metadata.golf'));
    assert.equal(reader.metadata.length, 2);
    assert.equal(reader.metadata[0].key, 'source');
    assert.equal(reader.metadata[0].value, 'fixture-generator');
  });

  test('read compressed_lz4.golf', { skip: !fixtureExists }, () => {
    const reader = GolfReader.open(path.join(TESTDATA_DIR, 'compressed_lz4.golf'));
    assert.equal(reader.recordCount, 100n);
    const result = reader.query(0n, 49500n);
    assert.equal(result.length, 100);
  });

  // Cross-language: Go fixtures
  test('read go_small.golf', { skip: !fs.existsSync(path.join(TESTDATA_DIR, 'go_small.golf')) }, () => {
    const reader = GolfReader.open(path.join(TESTDATA_DIR, 'go_small.golf'));
    assert.equal(reader.recordCount, 20n);
    const result = reader.query(0n, 19000n);
    assert.equal(result.length, 20);
    assert.equal(result[0].value[0], 0);
    assert.equal(result[19].value[0], 19);
  });

  test('read go_lz4.golf', { skip: !fs.existsSync(path.join(TESTDATA_DIR, 'go_lz4.golf')) }, () => {
    const reader = GolfReader.open(path.join(TESTDATA_DIR, 'go_lz4.golf'));
    assert.equal(reader.recordCount, 100n);
    const result = reader.query(0n, 49500n);
    assert.equal(result.length, 100);
  });

  test('read go_metadata.golf', { skip: !fs.existsSync(path.join(TESTDATA_DIR, 'go_metadata.golf')) }, () => {
    const reader = GolfReader.open(path.join(TESTDATA_DIR, 'go_metadata.golf'));
    assert.equal(reader.metadata[0].key, 'source');
    assert.equal(reader.metadata[0].value, 'go-generator');
  });

  // Cross-language: Python fixtures
  test('read py_small.golf', { skip: !fs.existsSync(path.join(TESTDATA_DIR, 'py_small.golf')) }, () => {
    const reader = GolfReader.open(path.join(TESTDATA_DIR, 'py_small.golf'));
    assert.equal(reader.recordCount, 20n);
    const result = reader.query(0n, 19000n);
    assert.equal(result.length, 20);
  });

  test('read py_lz4.golf', { skip: !fs.existsSync(path.join(TESTDATA_DIR, 'py_lz4.golf')) }, () => {
    const reader = GolfReader.open(path.join(TESTDATA_DIR, 'py_lz4.golf'));
    assert.equal(reader.recordCount, 100n);
    const result = reader.query(0n, 49500n);
    assert.equal(result.length, 100);
  });

  test('read py_metadata.golf', { skip: !fs.existsSync(path.join(TESTDATA_DIR, 'py_metadata.golf')) }, () => {
    const reader = GolfReader.open(path.join(TESTDATA_DIR, 'py_metadata.golf'));
    assert.equal(reader.metadata[0].key, 'source');
    assert.equal(reader.metadata[0].value, 'python-generator');
  });
});
