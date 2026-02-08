/**
 * GolfReader: read-only access to .golf files with range query support.
 */

import * as fs from 'node:fs';
import {
  type Header,
  type MetadataEntry,
  type BlockDescriptor,
  type Record,
  type Footer,
  Compression,
  FIXED_HEADER_SIZE,
  BLOCK_DESCRIPTOR_SIZE,
  FOOTER_SIZE,
  decodeHeader,
  decodeMetadata,
  decodeBlockDescriptor,
  decodeFooter,
  decompressBlock,
  computeCrc32c,
  extractRecord,
  findFirstBlock,
  findLastBlock,
  binarySearchFirst,
  binarySearchLast,
} from './core.js';

function collectRange(
  descriptors: BlockDescriptor[],
  compression: Compression,
  recordValueSize: number,
  startTs: bigint,
  endTs: bigint,
  readBlock: (desc: BlockDescriptor) => Buffer,
): Record[] {
  const firstIdx = findFirstBlock(descriptors, startTs);
  if (firstIdx < 0) return [];
  const lastIdx = findLastBlock(descriptors, endTs);
  if (lastIdx < 0) return [];
  if (firstIdx > lastIdx) return [];

  const recordSize = 8 + recordValueSize;
  const results: Record[] = [];

  for (let bi = firstIdx; bi <= lastIdx; bi++) {
    const desc = descriptors[bi];
    const compressed = readBlock(desc);
    const raw = decompressBlock(compressed, compression, desc.uncompressedSize);

    // Verify CRC
    const actualCrc = computeCrc32c(raw);
    if (actualCrc !== desc.blockCrc) {
      throw new Error(`block CRC mismatch: expected ${desc.blockCrc}, got ${actualCrc}`);
    }

    const count = desc.recordCount;
    let recStart = 0;
    let recEnd = count - 1;

    if (bi === firstIdx) {
      recStart = binarySearchFirst(raw, recordSize, count, startTs);
    }
    if (bi === lastIdx) {
      recEnd = binarySearchLast(raw, recordSize, count, endTs);
    }

    if (recStart <= recEnd && recEnd < count) {
      for (let i = recStart; i <= recEnd; i++) {
        const rec = extractRecord(raw, i, recordValueSize);
        if (rec.timestamp >= startTs && rec.timestamp <= endTs) {
          results.push(rec);
        }
      }
    }
  }

  return results;
}

/** Reader using a Buffer (in-memory). */
export class GolfReader {
  readonly header: Header;
  readonly metadata: MetadataEntry[];
  readonly descriptors: BlockDescriptor[];
  private data: Buffer;

  private constructor(data: Buffer) {
    this.data = data;

    if (data.length < FIXED_HEADER_SIZE + FOOTER_SIZE) {
      throw new Error(`file too small: ${data.length} bytes`);
    }

    // Read footer
    const footerBuf = data.subarray(data.length - FOOTER_SIZE);
    const footer = decodeFooter(footerBuf);

    // Read block index
    const indexStart = Number(footer.indexOffset);
    const indexSize = Number(footer.blockCount) * BLOCK_DESCRIPTOR_SIZE;
    const indexBuf = data.subarray(indexStart, indexStart + indexSize);
    const actualIndexCrc = computeCrc32c(indexBuf);
    if (actualIndexCrc !== footer.indexCrc) {
      throw new Error('block index CRC mismatch');
    }

    this.descriptors = [];
    for (let i = 0; i < Number(footer.blockCount); i++) {
      const off = i * BLOCK_DESCRIPTOR_SIZE;
      this.descriptors.push(decodeBlockDescriptor(indexBuf, off));
    }

    // Read header
    this.header = decodeHeader(data.subarray(0, FIXED_HEADER_SIZE));

    // Read metadata
    if (this.header.metadataLength > 0) {
      const metaBuf = data.subarray(FIXED_HEADER_SIZE, FIXED_HEADER_SIZE + this.header.metadataLength);
      this.metadata = decodeMetadata(metaBuf);
    } else {
      this.metadata = [];
    }
  }

  /** Open from a Buffer. */
  static fromBuffer(data: Buffer): GolfReader {
    return new GolfReader(data);
  }

  /** Open from a file path. */
  static open(path: string): GolfReader {
    const data = fs.readFileSync(path);
    return new GolfReader(data);
  }

  get recordCount(): bigint {
    return this.header.recordCount;
  }

  get timestampRange(): [bigint, bigint] {
    return [this.header.minTimestamp, this.header.maxTimestamp];
  }

  /** Query records in the inclusive range [startTs, endTs]. */
  query(startTs: bigint, endTs: bigint): Record[] {
    return collectRange(
      this.descriptors,
      this.header.compression,
      this.header.recordValueSize,
      startTs,
      endTs,
      (desc) => this.data.subarray(Number(desc.blockOffset), Number(desc.blockOffset) + desc.compressedSize),
    );
  }
}

/** Alias for GolfReader since TS uses buffer-based reading (portable "mmap" equivalent). */
export const MmapGolfReader = GolfReader;
