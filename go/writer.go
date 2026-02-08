package golf

import (
	"bufio"
	"fmt"
	"io"
	"sort"
)

// WriterConfig configures a GolfWriter.
type WriterConfig struct {
	RecordValueSize uint32
	TsResolution    TimestampResolution
	Compression     Compression
	BlockCapacity   uint32
	Metadata        []MetadataEntry
}

// GolfWriter accumulates records and seals them into a .golf file.
type GolfWriter struct {
	config  WriterConfig
	records []Record
	sealed  bool
}

// NewWriter creates a new GolfWriter with the given configuration.
func NewWriter(config WriterConfig) *GolfWriter {
	if config.BlockCapacity == 0 {
		config.BlockCapacity = 8192
	}
	return &GolfWriter{
		config: config,
	}
}

// Append adds a record. The value must be exactly RecordValueSize bytes.
func (w *GolfWriter) Append(timestamp uint64, value []byte) error {
	if w.sealed {
		return fmt.Errorf("writer already sealed")
	}
	if uint32(len(value)) != w.config.RecordValueSize {
		return fmt.Errorf("value size mismatch: expected %d, got %d", w.config.RecordValueSize, len(value))
	}
	v := make([]byte, len(value))
	copy(v, value)
	w.records = append(w.records, Record{Timestamp: timestamp, Value: v})
	return nil
}

// Len returns the number of records appended.
func (w *GolfWriter) Len() int {
	return len(w.records)
}

// Seal sorts, compresses, and writes the .golf file. Consumes the writer.
func (w *GolfWriter) Seal(dest io.Writer) error {
	if w.sealed {
		return fmt.Errorf("writer already sealed")
	}
	if len(w.records) == 0 {
		return fmt.Errorf("no records to seal")
	}
	w.sealed = true

	// Sort by timestamp
	sort.Slice(w.records, func(i, j int) bool {
		return w.records[i].Timestamp < w.records[j].Timestamp
	})

	bw := bufio.NewWriter(dest)

	metaBytes := EncodeMetadata(w.config.Metadata)
	minTs := w.records[0].Timestamp
	maxTs := w.records[len(w.records)-1].Timestamp

	header := Header{
		Version:         FormatVersion,
		Flags:           0,
		RecordValueSize: w.config.RecordValueSize,
		TsResolution:    w.config.TsResolution,
		Compression:     w.config.Compression,
		BlockCapacity:   w.config.BlockCapacity,
		MinTimestamp:     minTs,
		MaxTimestamp:     maxTs,
		RecordCount:     uint64(len(w.records)),
		MetadataLength:  uint32(len(metaBytes)),
	}

	// Write header
	headerBuf := EncodeHeader(&header)
	if _, err := bw.Write(headerBuf[:]); err != nil {
		return err
	}
	if len(metaBytes) > 0 {
		if _, err := bw.Write(metaBytes); err != nil {
			return err
		}
	}

	offset := uint64(FixedHeaderSize) + uint64(len(metaBytes))

	// Build and write blocks
	blockCap := int(w.config.BlockCapacity)
	var descriptors []BlockDescriptor

	for i := 0; i < len(w.records); i += blockCap {
		end := i + blockCap
		if end > len(w.records) {
			end = len(w.records)
		}
		chunk := w.records[i:end]

		raw := SerializeBlock(chunk, w.config.RecordValueSize)
		blockCRC := computeCRC32C(raw)
		uncompressedSize := uint32(len(raw))

		compressed, err := CompressBlock(raw, w.config.Compression)
		if err != nil {
			return fmt.Errorf("compress block: %w", err)
		}
		compressedSize := uint32(len(compressed))

		descriptors = append(descriptors, BlockDescriptor{
			MinTs:            chunk[0].Timestamp,
			MaxTs:            chunk[len(chunk)-1].Timestamp,
			BlockOffset:      offset,
			CompressedSize:   compressedSize,
			UncompressedSize: uncompressedSize,
			RecordCount:      uint32(len(chunk)),
			BlockCRC:         blockCRC,
		})

		if _, err := bw.Write(compressed); err != nil {
			return err
		}
		offset += uint64(compressedSize)
	}

	// Write block index
	indexOffset := offset
	var indexBuf []byte
	for _, d := range descriptors {
		db := EncodeBlockDescriptor(&d)
		indexBuf = append(indexBuf, db[:]...)
	}
	indexCRC := computeCRC32C(indexBuf)
	if _, err := bw.Write(indexBuf); err != nil {
		return err
	}

	// Write footer
	footer := Footer{
		IndexOffset: indexOffset,
		BlockCount:  uint64(len(descriptors)),
		IndexCRC:    indexCRC,
	}
	footerBuf := EncodeFooter(&footer)
	if _, err := bw.Write(footerBuf[:]); err != nil {
		return err
	}

	return bw.Flush()
}
