/**
 * Core data types and encoding/decoding for the golf file format.
 */

// @ts-ignore - no types for crc-32
import CRC32C from 'crc-32/crc32c.js';
import lz4 from 'lz4js';
import * as zlib from 'node:zlib';

// Constants
export const FIXED_HEADER_SIZE = 64;
export const BLOCK_DESCRIPTOR_SIZE = 40;
export const FOOTER_SIZE = 32;
export const FORMAT_VERSION = 1;
export const HEADER_MAGIC = Buffer.from('GOLF', 'ascii');
export const FOOTER_MAGIC = Buffer.from('FLOG', 'ascii');

export enum TimestampResolution {
  Nanoseconds = 0,
  Microseconds = 1,
  Milliseconds = 2,
}

export enum Compression {
  None = 0,
  Lz4 = 1,
  Zstd = 2,
}

export interface Header {
  version: number;
  flags: number;
  recordValueSize: number;
  tsResolution: TimestampResolution;
  compression: Compression;
  blockCapacity: number;
  minTimestamp: bigint;
  maxTimestamp: bigint;
  recordCount: bigint;
  metadataLength: number;
}

export interface MetadataEntry {
  key: string;
  value: string;
}

export interface BlockDescriptor {
  minTs: bigint;
  maxTs: bigint;
  blockOffset: bigint;
  compressedSize: number;
  uncompressedSize: number;
  recordCount: number;
  blockCrc: number;
}

export interface Record {
  timestamp: bigint;
  value: Buffer;
}

export interface Footer {
  indexOffset: bigint;
  blockCount: bigint;
  indexCrc: number;
}

/** Compute CRC-32C (Castagnoli) checksum as unsigned 32-bit integer. */
export function computeCrc32c(data: Buffer | Uint8Array): number {
  return CRC32C.buf(data) >>> 0;
}

// ── Header encoding/decoding ──

export function encodeHeader(h: Header): Buffer {
  const buf = Buffer.alloc(FIXED_HEADER_SIZE);
  HEADER_MAGIC.copy(buf, 0);
  buf.writeUInt16LE(h.version, 4);
  buf.writeUInt16LE(h.flags, 6);
  buf.writeUInt32LE(h.recordValueSize, 8);
  buf[12] = h.tsResolution;
  buf[13] = h.compression;
  buf.writeUInt32LE(h.blockCapacity, 14);
  // 18..28 reserved (zeros)
  buf.writeBigUInt64LE(h.minTimestamp, 28);
  buf.writeBigUInt64LE(h.maxTimestamp, 36);
  buf.writeBigUInt64LE(h.recordCount, 44);
  buf.writeUInt32LE(h.metadataLength, 52);
  const crc = computeCrc32c(buf.subarray(0, 56));
  buf.writeUInt32LE(crc, 56);
  // 60..64 padding (zeros)
  return buf;
}

export function decodeHeader(buf: Buffer): Header {
  if (buf.length < FIXED_HEADER_SIZE) {
    throw new Error(`expected ${FIXED_HEADER_SIZE} bytes, got ${buf.length}`);
  }
  if (!buf.subarray(0, 4).equals(HEADER_MAGIC)) {
    throw new Error('invalid header magic');
  }
  const version = buf.readUInt16LE(4);
  if (version !== FORMAT_VERSION) {
    throw new Error(`unsupported version: ${version}`);
  }
  const storedCrc = buf.readUInt32LE(56);
  const computedCrc = computeCrc32c(buf.subarray(0, 56));
  if (storedCrc !== computedCrc) {
    throw new Error(`header CRC mismatch: expected ${computedCrc}, got ${storedCrc}`);
  }
  return {
    version,
    flags: buf.readUInt16LE(6),
    recordValueSize: buf.readUInt32LE(8),
    tsResolution: buf[12] as TimestampResolution,
    compression: buf[13] as Compression,
    blockCapacity: buf.readUInt32LE(14),
    minTimestamp: buf.readBigUInt64LE(28),
    maxTimestamp: buf.readBigUInt64LE(36),
    recordCount: buf.readBigUInt64LE(44),
    metadataLength: buf.readUInt32LE(52),
  };
}

// ── Metadata encoding/decoding ──

export function encodeMetadata(entries: MetadataEntry[]): Buffer {
  const parts: Buffer[] = [];
  for (const e of entries) {
    const kb = Buffer.from(e.key, 'utf-8');
    const vb = Buffer.from(e.value, 'utf-8');
    const kLen = Buffer.alloc(2);
    kLen.writeUInt16LE(kb.length);
    parts.push(kLen, kb);
    const vLen = Buffer.alloc(2);
    vLen.writeUInt16LE(vb.length);
    parts.push(vLen, vb);
  }
  return Buffer.concat(parts);
}

export function decodeMetadata(data: Buffer): MetadataEntry[] {
  const entries: MetadataEntry[] = [];
  let offset = 0;
  while (offset < data.length) {
    if (offset + 2 > data.length) throw new Error('truncated metadata key length');
    const keyLen = data.readUInt16LE(offset);
    offset += 2;
    if (offset + keyLen > data.length) throw new Error('truncated metadata key');
    const key = data.subarray(offset, offset + keyLen).toString('utf-8');
    offset += keyLen;

    if (offset + 2 > data.length) throw new Error('truncated metadata value length');
    const valLen = data.readUInt16LE(offset);
    offset += 2;
    if (offset + valLen > data.length) throw new Error('truncated metadata value');
    const value = data.subarray(offset, offset + valLen).toString('utf-8');
    offset += valLen;

    entries.push({ key, value });
  }
  return entries;
}

// ── Block descriptor encoding/decoding ──

export function encodeBlockDescriptor(d: BlockDescriptor): Buffer {
  const buf = Buffer.alloc(BLOCK_DESCRIPTOR_SIZE);
  buf.writeBigUInt64LE(d.minTs, 0);
  buf.writeBigUInt64LE(d.maxTs, 8);
  buf.writeBigUInt64LE(d.blockOffset, 16);
  buf.writeUInt32LE(d.compressedSize, 24);
  buf.writeUInt32LE(d.uncompressedSize, 28);
  buf.writeUInt32LE(d.recordCount, 32);
  buf.writeUInt32LE(d.blockCrc, 36);
  return buf;
}

export function decodeBlockDescriptor(buf: Buffer, offset = 0): BlockDescriptor {
  return {
    minTs: buf.readBigUInt64LE(offset),
    maxTs: buf.readBigUInt64LE(offset + 8),
    blockOffset: buf.readBigUInt64LE(offset + 16),
    compressedSize: buf.readUInt32LE(offset + 24),
    uncompressedSize: buf.readUInt32LE(offset + 28),
    recordCount: buf.readUInt32LE(offset + 32),
    blockCrc: buf.readUInt32LE(offset + 36),
  };
}

// ── Footer encoding/decoding ──

export function encodeFooter(f: Footer): Buffer {
  const buf = Buffer.alloc(FOOTER_SIZE);
  buf.writeBigUInt64LE(f.indexOffset, 0);
  buf.writeBigUInt64LE(f.blockCount, 8);
  buf.writeUInt32LE(f.indexCrc, 16);
  FOOTER_MAGIC.copy(buf, 20);
  const crc = computeCrc32c(buf.subarray(0, 24));
  buf.writeUInt32LE(crc, 24);
  // 28..32 padding
  return buf;
}

export function decodeFooter(buf: Buffer): Footer {
  if (buf.length < FOOTER_SIZE) {
    throw new Error(`expected ${FOOTER_SIZE} bytes, got ${buf.length}`);
  }
  if (!buf.subarray(20, 24).equals(FOOTER_MAGIC)) {
    throw new Error('invalid footer magic');
  }
  const storedCrc = buf.readUInt32LE(24);
  const computedCrc = computeCrc32c(buf.subarray(0, 24));
  if (storedCrc !== computedCrc) {
    throw new Error(`footer CRC mismatch: expected ${computedCrc}, got ${storedCrc}`);
  }
  return {
    indexOffset: buf.readBigUInt64LE(0),
    blockCount: buf.readBigUInt64LE(8),
    indexCrc: buf.readUInt32LE(16),
  };
}

// ── Compression ──

/**
 * Compress block data.
 * LZ4 uses the lz4_flex prepend-size format: [4 bytes LE uncompressed size][LZ4 block data]
 */
export function compressBlock(data: Buffer, codec: Compression): Buffer {
  if (codec === Compression.None) {
    return data;
  } else if (codec === Compression.Lz4) {
    const src = new Uint8Array(data);
    const bound = lz4.compressBound(src.length);
    const dst = lz4.makeBuffer(bound);
    const compressedSize = lz4.compressBlock(src, dst, 0, src.length, lz4.makeBuffer(1 << 16));

    // Prepend uncompressed size as LE u32
    const result = Buffer.alloc(4 + compressedSize);
    result.writeUInt32LE(src.length, 0);
    Buffer.from(dst.buffer, dst.byteOffset, compressedSize).copy(result, 4);
    return result;
  } else if (codec === Compression.Zstd) {
    // Node.js doesn't have native zstd; we'll use a simple fallback
    throw new Error('Zstd compression not supported in TypeScript writer (use Zstd reader for cross-language compat)');
  }
  throw new Error(`unsupported compression: ${codec}`);
}

/**
 * Decompress block data.
 * LZ4 expects the lz4_flex prepend-size format.
 */
export function decompressBlock(data: Buffer, codec: Compression, uncompressedSize: number): Buffer {
  if (codec === Compression.None) {
    return data;
  } else if (codec === Compression.Lz4) {
    if (data.length < 4) throw new Error('LZ4 data too short');
    const origSize = data.readUInt32LE(0);
    const src = new Uint8Array(data.subarray(4));
    const dst = lz4.makeBuffer(origSize);
    lz4.decompressBlock(src, dst, 0, src.length, 0);
    return Buffer.from(dst.buffer, dst.byteOffset, origSize);
  } else if (codec === Compression.Zstd) {
    // Use Node.js built-in brotli? No. We need actual zstd.
    // For cross-language reading of zstd-compressed files, we need a zstd library.
    // Since zstd is not natively supported in Node.js, we'll skip zstd support
    // in the TypeScript implementation for now. Users can use non-zstd compression.
    throw new Error('Zstd decompression not yet supported in TypeScript');
  }
  throw new Error(`unsupported compression: ${codec}`);
}

// ── Record serialization ──

export function serializeBlock(records: Record[], recordValueSize: number): Buffer {
  const recordSize = 8 + recordValueSize;
  const buf = Buffer.alloc(records.length * recordSize);
  for (let i = 0; i < records.length; i++) {
    const off = i * recordSize;
    buf.writeBigUInt64LE(records[i].timestamp, off);
    records[i].value.copy(buf, off + 8);
  }
  return buf;
}

export function extractRecord(data: Buffer, index: number, recordValueSize: number): Record {
  const recordSize = 8 + recordValueSize;
  const off = index * recordSize;
  return {
    timestamp: data.readBigUInt64LE(off),
    value: Buffer.from(data.subarray(off + 8, off + recordSize)),
  };
}

// ── Binary search helpers ──

export function findFirstBlock(descriptors: BlockDescriptor[], target: bigint): number {
  let lo = 0;
  let hi = descriptors.length;
  while (lo < hi) {
    const mid = lo + ((hi - lo) >> 1);
    if (descriptors[mid].maxTs < target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo < descriptors.length ? lo : -1;
}

export function findLastBlock(descriptors: BlockDescriptor[], target: bigint): number {
  let lo = 0;
  let hi = descriptors.length;
  while (lo < hi) {
    const mid = lo + ((hi - lo) >> 1);
    if (descriptors[mid].minTs <= target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo > 0 ? lo - 1 : -1;
}

export function binarySearchFirst(data: Buffer, recordSize: number, count: number, target: bigint): number {
  let lo = 0;
  let hi = count;
  while (lo < hi) {
    const mid = lo + ((hi - lo) >> 1);
    const ts = data.readBigUInt64LE(mid * recordSize);
    if (ts < target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

export function binarySearchLast(data: Buffer, recordSize: number, count: number, target: bigint): number {
  let lo = 0;
  let hi = count;
  while (lo < hi) {
    const mid = lo + ((hi - lo) >> 1);
    const ts = data.readBigUInt64LE(mid * recordSize);
    if (ts <= target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return Math.max(0, lo - 1);
}
