// generate_fixtures generates cross-language test fixtures from Go.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	golf "github.com/golf-format/golf-go"
)

func main() {
	outputDir := filepath.Join("..", "..", "testdata")
	if len(os.Args) > 1 {
		outputDir = os.Args[1]
	}
	os.MkdirAll(outputDir, 0o755)

	generateSmall(outputDir)
	generateLz4(outputDir)
	generateMetadata(outputDir)

	fmt.Printf("Generated Go fixtures in %s\n", outputDir)
}

func generateSmall(dir string) {
	w := golf.NewWriter(golf.WriterConfig{
		RecordValueSize: 8,
		TsResolution:    golf.TsNanoseconds,
		Compression:     golf.CompressionNone,
		BlockCapacity:   4,
	})
	for i := uint64(0); i < 20; i++ {
		val := make([]byte, 8)
		val[0] = byte(i)
		w.Append(i*1000, val)
	}
	f, _ := os.Create(filepath.Join(dir, "go_small.golf"))
	defer f.Close()
	w.Seal(f)
	fmt.Println("  go_small.golf: 20 records, no compression")
}

func generateLz4(dir string) {
	w := golf.NewWriter(golf.WriterConfig{
		RecordValueSize: 16,
		TsResolution:    golf.TsMicroseconds,
		Compression:     golf.CompressionLz4,
		BlockCapacity:   8,
	})
	for i := uint64(0); i < 100; i++ {
		val := make([]byte, 16)
		val[0] = byte(i & 0xff)
		val[1] = byte((i >> 8) & 0xff)
		w.Append(i*500, val)
	}
	f, _ := os.Create(filepath.Join(dir, "go_lz4.golf"))
	defer f.Close()
	w.Seal(f)
	fmt.Println("  go_lz4.golf: 100 records, LZ4")
}

func generateMetadata(dir string) {
	w := golf.NewWriter(golf.WriterConfig{
		RecordValueSize: 8,
		TsResolution:    golf.TsNanoseconds,
		Compression:     golf.CompressionNone,
		BlockCapacity:   4,
		Metadata: []golf.MetadataEntry{
			{Key: "source", Value: "go-generator"},
			{Key: "version", Value: "0.1.0"},
		},
	})
	for i := uint64(0); i < 10; i++ {
		val := make([]byte, 8)
		val[0] = byte(i)
		w.Append(i*1000, val)
	}
	f, _ := os.Create(filepath.Join(dir, "go_metadata.golf"))
	defer f.Close()
	w.Seal(f)
	fmt.Println("  go_metadata.golf: 10 records, with metadata")
}
