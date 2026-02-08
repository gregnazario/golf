package golf

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func buildInMemory(t *testing.T, records []Record, config WriterConfig) []byte {
	t.Helper()
	w := NewWriter(config)
	for _, r := range records {
		if err := w.Append(r.Timestamp, r.Value); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	var buf bytes.Buffer
	if err := w.Seal(&buf); err != nil {
		t.Fatalf("seal: %v", err)
	}
	return buf.Bytes()
}

func makeRecords(n int, valueSize int, tsStep uint64) []Record {
	records := make([]Record, n)
	for i := 0; i < n; i++ {
		val := make([]byte, valueSize)
		val[0] = byte(i & 0xff)
		records[i] = Record{
			Timestamp: uint64(i) * tsStep,
			Value:     val,
		}
	}
	return records
}

func TestRoundtripNoCompression(t *testing.T) {
	records := makeRecords(20, 8, 1000)
	data := buildInMemory(t, records, WriterConfig{
		RecordValueSize: 8,
		Compression:     CompressionNone,
		BlockCapacity:   4,
	})

	reader, err := OpenReader(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if reader.Header.RecordCount != 20 {
		t.Fatalf("expected 20 records, got %d", reader.Header.RecordCount)
	}

	result, err := reader.Query(0, 19000)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(result) != 20 {
		t.Fatalf("expected 20 results, got %d", len(result))
	}
	for i, r := range result {
		if r.Timestamp != uint64(i)*1000 {
			t.Errorf("record %d: expected ts %d, got %d", i, i*1000, r.Timestamp)
		}
	}
}

func TestRoundtripLz4(t *testing.T) {
	records := makeRecords(100, 16, 500)
	data := buildInMemory(t, records, WriterConfig{
		RecordValueSize: 16,
		Compression:     CompressionLz4,
		BlockCapacity:   8,
	})

	reader, err := OpenReader(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	result, err := reader.Query(5000, 10000)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(result) != 11 {
		t.Fatalf("expected 11 results, got %d", len(result))
	}
}

func TestRoundtripZstd(t *testing.T) {
	records := makeRecords(50, 8, 100)
	data := buildInMemory(t, records, WriterConfig{
		RecordValueSize: 8,
		Compression:     CompressionZstd,
		BlockCapacity:   16,
	})

	reader, err := OpenReader(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	result, err := reader.Query(2500, 2500)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(result) != 1 {
		t.Fatalf("expected 1 result, got %d", len(result))
	}
	if result[0].Timestamp != 2500 {
		t.Errorf("expected ts 2500, got %d", result[0].Timestamp)
	}
}

func TestUnsortedInput(t *testing.T) {
	w := NewWriter(WriterConfig{
		RecordValueSize: 4,
		Compression:     CompressionNone,
		BlockCapacity:   4,
	})
	pairs := []struct {
		ts  uint64
		val byte
	}{
		{300, 3}, {100, 1}, {200, 2}, {500, 5}, {400, 4},
	}
	for _, p := range pairs {
		w.Append(p.ts, []byte{p.val, 0, 0, 0})
	}
	var buf bytes.Buffer
	w.Seal(&buf)

	reader, _ := OpenReader(bytes.NewReader(buf.Bytes()))
	result, _ := reader.Query(0, 600)
	expected := []uint64{100, 200, 300, 400, 500}
	for i, r := range result {
		if r.Timestamp != expected[i] {
			t.Errorf("record %d: expected %d, got %d", i, expected[i], r.Timestamp)
		}
	}
}

func TestMetadataRoundtrip(t *testing.T) {
	records := makeRecords(5, 8, 100)
	data := buildInMemory(t, records, WriterConfig{
		RecordValueSize: 8,
		Compression:     CompressionNone,
		BlockCapacity:   4,
		Metadata: []MetadataEntry{
			{Key: "source", Value: "test-suite"},
			{Key: "version", Value: "1.0.0"},
		},
	})

	reader, err := OpenReader(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if len(reader.Metadata) != 2 {
		t.Fatalf("expected 2 metadata entries, got %d", len(reader.Metadata))
	}
	if reader.Metadata[0].Key != "source" || reader.Metadata[0].Value != "test-suite" {
		t.Errorf("unexpected metadata[0]: %+v", reader.Metadata[0])
	}
}

func TestEmptyRange(t *testing.T) {
	records := makeRecords(10, 8, 100)
	data := buildInMemory(t, records, WriterConfig{
		RecordValueSize: 8,
		Compression:     CompressionNone,
		BlockCapacity:   4,
	})

	reader, _ := OpenReader(bytes.NewReader(data))

	// Query after all records
	result, _ := reader.Query(1000, 2000)
	if len(result) != 0 {
		t.Errorf("expected 0 results, got %d", len(result))
	}
}

// Cross-language fixture tests
func TestReadRustFixtureSmall(t *testing.T) {
	path := filepath.Join("..", "testdata", "small.golf")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Skip("fixture not found, run Rust generate_fixtures first")
	}
	reader, err := OpenFile(path)
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	if reader.Header.RecordCount != 20 {
		t.Fatalf("expected 20 records, got %d", reader.Header.RecordCount)
	}
	if reader.Header.RecordValueSize != 8 {
		t.Fatalf("expected value size 8, got %d", reader.Header.RecordValueSize)
	}
	result, err := reader.Query(0, 19000)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(result) != 20 {
		t.Fatalf("expected 20 results, got %d", len(result))
	}
	// Verify first record
	if result[0].Timestamp != 0 || result[0].Value[0] != 0 {
		t.Errorf("unexpected first record: ts=%d val[0]=%d", result[0].Timestamp, result[0].Value[0])
	}
	// Verify last record
	last := result[len(result)-1]
	if last.Timestamp != 19000 || last.Value[0] != 19 {
		t.Errorf("unexpected last record: ts=%d val[0]=%d", last.Timestamp, last.Value[0])
	}
}

func TestReadRustFixtureWithMetadata(t *testing.T) {
	path := filepath.Join("..", "testdata", "with_metadata.golf")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Skip("fixture not found")
	}
	reader, err := OpenFile(path)
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	if len(reader.Metadata) != 2 {
		t.Fatalf("expected 2 metadata entries, got %d", len(reader.Metadata))
	}
	if reader.Metadata[0].Key != "source" || reader.Metadata[0].Value != "fixture-generator" {
		t.Errorf("unexpected metadata: %+v", reader.Metadata[0])
	}
}

// ── Cross-language compatibility: read fixtures from Python and TypeScript ──

func assertSmallFixture(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Skipf("fixture not found: %s", path)
	}
	reader, err := OpenFile(path)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	if reader.Header.RecordCount != 20 {
		t.Fatalf("expected 20 records, got %d", reader.Header.RecordCount)
	}
	result, err := reader.Query(0, 19000)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(result) != 20 {
		t.Fatalf("expected 20 results, got %d", len(result))
	}
	if result[0].Timestamp != 0 || result[0].Value[0] != 0 {
		t.Errorf("unexpected first record")
	}
	last := result[len(result)-1]
	if last.Timestamp != 19000 || last.Value[0] != 19 {
		t.Errorf("unexpected last record")
	}
}

func assertLz4Fixture(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Skipf("fixture not found: %s", path)
	}
	reader, err := OpenFile(path)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	if reader.Header.RecordCount != 100 {
		t.Fatalf("expected 100 records, got %d", reader.Header.RecordCount)
	}
	result, err := reader.Query(0, 49500)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if len(result) != 100 {
		t.Fatalf("expected 100 results, got %d", len(result))
	}
}

func assertMetadataFixture(t *testing.T, path, expectedSource string) {
	t.Helper()
	if _, err := os.Stat(path); os.IsNotExist(err) {
		t.Skipf("fixture not found: %s", path)
	}
	reader, err := OpenFile(path)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	if len(reader.Metadata) != 2 {
		t.Fatalf("expected 2 metadata entries, got %d", len(reader.Metadata))
	}
	if reader.Metadata[0].Key != "source" || reader.Metadata[0].Value != expectedSource {
		t.Errorf("unexpected metadata: %+v", reader.Metadata[0])
	}
}

func TestReadPythonSmall(t *testing.T) {
	assertSmallFixture(t, filepath.Join("..", "testdata", "py_small.golf"))
}

func TestReadPythonLz4(t *testing.T) {
	assertLz4Fixture(t, filepath.Join("..", "testdata", "py_lz4.golf"))
}

func TestReadPythonMetadata(t *testing.T) {
	assertMetadataFixture(t, filepath.Join("..", "testdata", "py_metadata.golf"), "python-generator")
}

func TestReadTypescriptSmall(t *testing.T) {
	assertSmallFixture(t, filepath.Join("..", "testdata", "ts_small.golf"))
}

func TestReadTypescriptLz4(t *testing.T) {
	assertLz4Fixture(t, filepath.Join("..", "testdata", "ts_lz4.golf"))
}

func TestReadTypescriptMetadata(t *testing.T) {
	assertMetadataFixture(t, filepath.Join("..", "testdata", "ts_metadata.golf"), "typescript-generator")
}
