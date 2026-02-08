/**
 * Golf: Read-only indexed storage file format for time-series range queries.
 */

export { GolfWriter, WriterConfig } from './writer.js';
export { GolfReader, MmapGolfReader } from './reader.js';
export {
  Header,
  MetadataEntry,
  BlockDescriptor,
  Record,
  Footer,
  Compression,
  TimestampResolution,
  FIXED_HEADER_SIZE,
  BLOCK_DESCRIPTOR_SIZE,
  FOOTER_SIZE,
  FORMAT_VERSION,
  HEADER_MAGIC,
  FOOTER_MAGIC,
} from './core.js';
