/**
 * GolfWriter: append records, then seal into an immutable .golf file.
 */

import {
  type Header,
  type MetadataEntry,
  type BlockDescriptor,
  type Record,
  Compression,
  TimestampResolution,
  FORMAT_VERSION,
  FIXED_HEADER_SIZE,
  encodeHeader,
  encodeMetadata,
  encodeBlockDescriptor,
  encodeFooter,
  serializeBlock,
  compressBlock,
  computeCrc32c,
} from './core.js';

export interface WriterConfig {
  recordValueSize: number;
  tsResolution?: TimestampResolution;
  compression?: Compression;
  blockCapacity?: number;
  metadata?: MetadataEntry[];
}

export class GolfWriter {
  private config: Required<WriterConfig>;
  private records: Record[] = [];
  private sealed = false;

  constructor(config: WriterConfig) {
    this.config = {
      recordValueSize: config.recordValueSize,
      tsResolution: config.tsResolution ?? TimestampResolution.Nanoseconds,
      compression: config.compression ?? Compression.Lz4,
      blockCapacity: config.blockCapacity ?? 8192,
      metadata: config.metadata ?? [],
    };
  }

  /** Append a record. Value must be exactly recordValueSize bytes. */
  append(timestamp: bigint, value: Buffer): void {
    if (this.sealed) throw new Error('writer already sealed');
    if (value.length !== this.config.recordValueSize) {
      throw new Error(
        `value size mismatch: expected ${this.config.recordValueSize}, got ${value.length}`
      );
    }
    this.records.push({ timestamp, value: Buffer.from(value) });
  }

  get length(): number {
    return this.records.length;
  }

  /** Seal and return the complete .golf file as a Buffer. */
  seal(): Buffer {
    if (this.sealed) throw new Error('writer already sealed');
    if (this.records.length === 0) throw new Error('no records to seal');
    this.sealed = true;

    // Sort by timestamp
    this.records.sort((a, b) => (a.timestamp < b.timestamp ? -1 : a.timestamp > b.timestamp ? 1 : 0));

    const { recordValueSize, blockCapacity } = this.config;
    const metaBytes = encodeMetadata(this.config.metadata);

    const minTs = this.records[0].timestamp;
    const maxTs = this.records[this.records.length - 1].timestamp;

    const header: Header = {
      version: FORMAT_VERSION,
      flags: 0,
      recordValueSize,
      tsResolution: this.config.tsResolution,
      compression: this.config.compression,
      blockCapacity,
      minTimestamp: minTs,
      maxTimestamp: maxTs,
      recordCount: BigInt(this.records.length),
      metadataLength: metaBytes.length,
    };

    const parts: Buffer[] = [];

    // Write header
    parts.push(encodeHeader(header));
    if (metaBytes.length > 0) {
      parts.push(metaBytes);
    }

    let offset = BigInt(FIXED_HEADER_SIZE + metaBytes.length);

    // Build and write blocks
    const descriptors: BlockDescriptor[] = [];
    for (let i = 0; i < this.records.length; i += blockCapacity) {
      const chunk = this.records.slice(i, i + blockCapacity);
      const raw = serializeBlock(chunk, recordValueSize);
      const blockCrc = computeCrc32c(raw);
      const uncompressedSize = raw.length;

      const compressed = compressBlock(raw, this.config.compression);
      const compressedSize = compressed.length;

      descriptors.push({
        minTs: chunk[0].timestamp,
        maxTs: chunk[chunk.length - 1].timestamp,
        blockOffset: offset,
        compressedSize,
        uncompressedSize,
        recordCount: chunk.length,
        blockCrc,
      });

      parts.push(compressed);
      offset += BigInt(compressedSize);
    }

    // Write block index
    const indexOffset = offset;
    const indexParts = descriptors.map(d => encodeBlockDescriptor(d));
    const indexBytes = Buffer.concat(indexParts);
    const indexCrc = computeCrc32c(indexBytes);
    parts.push(indexBytes);

    // Write footer
    parts.push(
      encodeFooter({
        indexOffset,
        blockCount: BigInt(descriptors.length),
        indexCrc,
      })
    );

    return Buffer.concat(parts);
  }
}
