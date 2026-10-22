package knowledge

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const extractedTextLimit = 16 << 20

// extractDocumentText is enabled only by explicit community composition.
// Tools receive a private temporary file, never a user-controlled shell command.
func extractDocumentText(ctx context.Context, content []byte, mime string) (string, error) {
	ctx, cancelAll := context.WithTimeout(ctx, 120*time.Second)
	defer cancelAll()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if strings.HasPrefix(mime, "text/") || mime == "application/json" {
		if !utf8.Valid(content) || bytes.IndexByte(content, 0) >= 0 {
			return "", errors.New("document must contain UTF-8 text")
		}
		if len(content) > extractedTextLimit {
			return "", errors.New("document text exceeds limit")
		}
		if strings.TrimSpace(string(content)) == "" {
			return "", errors.New("document contains no text")
		}
		return string(content), nil
	}
	if strings.Contains(mime, "openxmlformats-officedocument") {
		return extractOfficeXML(ctx, content, mime)
	}
	dir, err := os.MkdirTemp("", "community-document-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(dir)
	input := filepath.Join(dir, "input")
	if err = os.WriteFile(input, content, 0600); err != nil {
		return "", err
	}
	var tool string
	var args []string
	switch mime {
	case "application/pdf":
		return extractPDF(ctx, input, dir)
	case "application/vnd.ms-excel", "application/vnd.ms-powerpoint":
		return extractLegacyOffice(ctx, content, mime, dir)
	case "application/msword":
		tool = "antiword"
		args = []string{"-m", "UTF-8.txt", input}
	case "image/png", "image/jpeg", "image/jpg", "image/gif", "image/tif", "image/tiff":
		tool = "tesseract"
		args = []string{input, "stdout", "-l", "chi_sim+eng"}
	default:
		return "", errors.New("document format requires an unavailable parser")
	}
	run, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(run, tool, args...)
	cmd.Dir = dir
	var out boundedText
	cmd.Stdout = &out
	if err = cmd.Run(); err != nil {
		return "", errors.New("document parser failed or is unavailable")
	}
	text := strings.TrimSpace(out.String())
	if text == "" {
		return "", errors.New("document contains no extractable text")
	}
	return text, nil
}

type boundedText struct{ bytes.Buffer }

func (b *boundedText) Write(p []byte) (int, error) {
	if b.Len()+len(p) > extractedTextLimit {
		return 0, errors.New("extracted text exceeds limit")
	}
	return b.Buffer.Write(p)
}

func extractOfficeXML(ctx context.Context, content []byte, mime string) (string, error) {
	z, err := zip.NewReader(bytes.NewReader(content), int64(len(content)))
	if err != nil {
		return "", errors.New("invalid Office document")
	}
	if len(z.File) > 4096 {
		return "", errors.New("Office archive contains too many files")
	}
	if strings.Contains(mime, "spreadsheetml") {
		return extractSpreadsheet(ctx, z)
	}
	var out boundedText
	var expanded uint64
	for _, f := range z.File {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		name := f.Name
		if !((strings.Contains(mime, "wordprocessingml") && strings.HasPrefix(name, "word/")) || (strings.Contains(mime, "presentationml") && strings.HasPrefix(name, "ppt/slides/"))) || !strings.HasSuffix(name, ".xml") {
			continue
		}
		if f.UncompressedSize64 > (32<<20)-expanded {
			return "", errors.New("expanded Office document exceeds limit")
		}
		expanded += f.UncompressedSize64
		if expanded > 32<<20 {
			return "", errors.New("expanded Office document exceeds limit")
		}
		r, err := f.Open()
		if err != nil {
			return "", err
		}
		dec := xml.NewDecoder(io.LimitReader(r, 32<<20))
		for {
			if err := ctx.Err(); err != nil {
				r.Close()
				return "", err
			}
			tok, e := dec.Token()
			if e == io.EOF {
				break
			}
			if e != nil {
				r.Close()
				return "", errors.New("invalid Office XML")
			}
			// Runs split text for formatting, not for word boundaries.
			separator := ""
			switch node := tok.(type) {
			case xml.EndElement:
				if node.Name.Local == "p" || node.Name.Local == "tr" {
					separator = "\n"
				} else if node.Name.Local == "tc" {
					separator = "\t"
				}
			case xml.StartElement:
				if node.Name.Local == "br" || node.Name.Local == "cr" {
					separator = "\n"
				} else if node.Name.Local == "tab" {
					separator = "\t"
				}
			}
			if separator != "" {
				if _, e = out.Write([]byte(separator)); e != nil {
					r.Close()
					return "", e
				}
			}
			start, ok := tok.(xml.StartElement)
			if !ok || start.Name.Local != "t" {
				continue
			}
			var text string
			if e = dec.DecodeElement(&text, &start); e != nil {
				r.Close()
				return "", e
			}
			if _, e = out.Write([]byte(text)); e != nil {
				r.Close()
				return "", e
			}
		}
		r.Close()
	}
	text := strings.TrimSpace(out.String())
	if text == "" {
		return "", errors.New("Office document contains no extractable text")
	}
	return text, nil
}

// richText preserves runs within a single shared or inline string.
type richText struct{ Text string }

func (r *richText) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	var out boundedText
	for {
		tok, err := d.Token()
		if err != nil {
			return err
		}
		switch t := tok.(type) {
		case xml.StartElement:
			// Phonetic guides annotate the preceding string; they are not body text.
			if t.Name.Local == "rPh" {
				if err := d.Skip(); err != nil {
					return err
				}
				continue
			}
			if t.Name.Local == "t" {
				var value string
				if err = d.DecodeElement(&value, &t); err != nil {
					return err
				}
				if _, err = out.Write([]byte(value)); err != nil {
					return err
				}
			}
		case xml.EndElement:
			if t.Name == start.Name {
				r.Text = out.String()
				return nil
			}
		}
	}
}
func extractSpreadsheet(ctx context.Context, z *zip.Reader) (string, error) {
	files := map[string]*zip.File{}
	var expanded uint64
	var sheets []string
	for _, f := range z.File {
		if f.Name != "xl/sharedStrings.xml" && !(strings.HasPrefix(f.Name, "xl/worksheets/") && strings.HasSuffix(f.Name, ".xml")) {
			continue
		}
		if f.UncompressedSize64 > (32<<20)-expanded {
			return "", errors.New("expanded spreadsheet exceeds limit")
		}
		expanded += f.UncompressedSize64
		if files[f.Name] != nil {
			return "", errors.New("duplicate spreadsheet part")
		}
		files[f.Name] = f
		if f.Name != "xl/sharedStrings.xml" {
			sheets = append(sheets, f.Name)
		}
	}
	var shared []string
	var sharedBytes int
	if f := files["xl/sharedStrings.xml"]; f != nil {
		err := readSpreadsheetXML(ctx, f, func(d *xml.Decoder, start xml.StartElement) error {
			if start.Name.Local != "si" {
				return nil
			}
			var text richText
			if err := d.DecodeElement(&text, &start); err != nil {
				return err
			}
			sharedBytes += len(text.Text)
			if sharedBytes > extractedTextLimit || len(shared) >= 250000 {
				return errors.New("spreadsheet shared strings exceed limit")
			}
			shared = append(shared, text.Text)
			return nil
		})
		if err != nil {
			return "", err
		}
	}
	sort.Strings(sheets)
	var nonEmpty bool
	var out boundedText
	for _, name := range sheets {
		if _, err := out.Write([]byte("[" + name + "]\n")); err != nil {
			return "", err
		}
		err := readSpreadsheetXML(ctx, files[name], func(d *xml.Decoder, start xml.StartElement) error {
			if start.Name.Local == "row" {
				_, err := out.Write([]byte("\n"))
				return err
			}
			if start.Name.Local != "c" {
				return nil
			}
			var cell struct {
				Type   string   `xml:"t,attr"`
				Ref    string   `xml:"r,attr"`
				Value  string   `xml:"v"`
				Inline richText `xml:"is"`
			}
			if err := d.DecodeElement(&cell, &start); err != nil {
				return err
			}
			value := cell.Value
			switch cell.Type {
			case "s":
				i, err := strconv.Atoi(strings.TrimSpace(value))
				if err != nil || i < 0 || i >= len(shared) {
					return errors.New("invalid spreadsheet shared string index")
				}
				value = shared[i]
			case "inlineStr":
				value = cell.Inline.Text
			case "b":
				if value == "1" {
					value = "TRUE"
				} else if value == "0" {
					value = "FALSE"
				}
			}
			if strings.TrimSpace(value) != "" {
				nonEmpty = true
			}
			_, err := out.Write([]byte(cell.Ref + "=" + value + "\t"))
			return err
		})
		if err != nil {
			return "", err
		}
		if _, err = out.Write([]byte("\n")); err != nil {
			return "", err
		}
	}
	if len(sheets) == 0 || !nonEmpty {
		return "", errors.New("spreadsheet contains no worksheets")
	}
	return strings.TrimSpace(out.String()), nil
}
func readSpreadsheetXML(ctx context.Context, f *zip.File, visit func(*xml.Decoder, xml.StartElement) error) error {
	r, err := f.Open()
	if err != nil {
		return err
	}
	defer r.Close()
	d := xml.NewDecoder(io.LimitReader(r, 32<<20))
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		tok, err := d.Token()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if start, ok := tok.(xml.StartElement); ok {
			if err := visit(d, start); err != nil {
				return err
			}
		}
	}
}
