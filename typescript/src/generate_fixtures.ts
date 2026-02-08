#!/usr/bin/env tsx
/**
 * Generate cross-language test fixtures from TypeScript.
 */

import * as fs from 'node:fs';
import * as path from 'node:path';
import { GolfWriter } from './writer.js';
import { Compression, TimestampResolution } from './core.js';

const outputDir = process.argv[2] || path.join(__dirname, '..', '..', 'testdata');
fs.mkdirSync(outputDir, { recursive: true });

// ts_small.golf: 20 records, no compression, value_size=8, block_capacity=4
{
  const w = new GolfWriter({
    recordValueSize: 8,
    tsResolution: TimestampResolution.Nanoseconds,
    compression: Compression.None,
    blockCapacity: 4,
  });
  for (let i = 0; i < 20; i++) {
    const val = Buffer.alloc(8);
    val[0] = i;
    w.append(BigInt(i) * 1000n, val);
  }
  fs.writeFileSync(path.join(outputDir, 'ts_small.golf'), w.seal());
  console.log('  ts_small.golf: 20 records, no compression');
}

// ts_lz4.golf: 100 records, LZ4, value_size=16, block_capacity=8
{
  const w = new GolfWriter({
    recordValueSize: 16,
    tsResolution: TimestampResolution.Microseconds,
    compression: Compression.Lz4,
    blockCapacity: 8,
  });
  for (let i = 0; i < 100; i++) {
    const val = Buffer.alloc(16);
    val[0] = i & 0xff;
    val[1] = (i >> 8) & 0xff;
    w.append(BigInt(i) * 500n, val);
  }
  fs.writeFileSync(path.join(outputDir, 'ts_lz4.golf'), w.seal());
  console.log('  ts_lz4.golf: 100 records, LZ4');
}

// ts_metadata.golf: 10 records, with metadata
{
  const w = new GolfWriter({
    recordValueSize: 8,
    tsResolution: TimestampResolution.Nanoseconds,
    compression: Compression.None,
    blockCapacity: 4,
    metadata: [
      { key: 'source', value: 'typescript-generator' },
      { key: 'version', value: '0.1.0' },
    ],
  });
  for (let i = 0; i < 10; i++) {
    const val = Buffer.alloc(8);
    val[0] = i;
    w.append(BigInt(i) * 1000n, val);
  }
  fs.writeFileSync(path.join(outputDir, 'ts_metadata.golf'), w.seal());
  console.log('  ts_metadata.golf: 10 records, with metadata');
}

console.log(`Generated TypeScript fixtures in ${outputDir}`);
