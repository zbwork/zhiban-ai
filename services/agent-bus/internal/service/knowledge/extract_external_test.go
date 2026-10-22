package knowledge

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestPDFMixedPages(t *testing.T) {
	dir := t.TempDir()
	scripts := map[string]string{
		"pdfinfo":   "echo 'Pages: 2'",
		"pdftotext": "if [ \"$2\" = 1 ]; then echo text-page; fi",
		"pdftoppm":  "touch ocr-page.png",
		"tesseract": "echo scanned-page",
	}
	for name, body := range scripts {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\n"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	got, err := extractPDF(context.Background(), "input.pdf", dir)
	if err != nil || got != "text-page\nscanned-page" {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "ocr-page.png")); !os.IsNotExist(err) {
		t.Fatalf("image retained: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "pdfinfo"), []byte("#!/bin/sh\necho 'Pages: 21'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := extractPDF(context.Background(), "input.pdf", dir); err == nil {
		t.Fatal("accepted excessive pages")
	}
}
