package knowledge

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func parserOutput(ctx context.Context, dir, tool string, args ...string) (string, error) {
	run, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(run, tool, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "LC_ALL=C", "HOME="+dir, "XDG_CACHE_HOME="+dir)
	var out boundedText
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s parser failed or is unavailable", tool)
	}
	return strings.TrimSpace(out.String()), nil
}

func extractPDF(ctx context.Context, input, dir string) (string, error) {
	info, err := parserOutput(ctx, dir, "pdfinfo", input)
	if err != nil {
		return "", err
	}
	pages := 0
	for _, line := range strings.Split(info, "\n") {
		if strings.HasPrefix(line, "Pages:") {
			pages, _ = strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "Pages:")))
		}
	}
	if pages < 1 || pages > 20 {
		return "", errors.New("PDF OCR requires 1 to 20 pages")
	}
	var out boundedText
	for page := 1; page <= pages; page++ {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		n := strconv.Itoa(page)
		text, err := parserOutput(ctx, dir, "pdftotext", "-f", n, "-l", n, "-enc", "UTF-8", input, "-")
		if err != nil {
			return "", err
		}
		if text == "" {
			prefix := filepath.Join(dir, "ocr-page")
			if _, err = parserOutput(ctx, dir, "pdftoppm", "-f", n, "-l", n, "-singlefile", "-scale-to", "2000", "-png", input, prefix); err != nil {
				return "", err
			}
			image := prefix + ".png"
			text, err = parserOutput(ctx, dir, "tesseract", image, "stdout", "-l", "chi_sim+eng")
			_ = os.Remove(image)
			if err != nil {
				return "", err
			}
		}
		if _, err = out.Write([]byte(text + "\n")); err != nil {
			return "", err
		}
	}
	text := strings.TrimSpace(out.String())
	if text == "" {
		return "", errors.New("PDF contains no recognizable text")
	}
	return text, nil
}

func extractLegacyOffice(ctx context.Context, content []byte, mime, dir string) (string, error) {
	ext, target, newMIME := "xls", "xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
	if mime == "application/vnd.ms-powerpoint" {
		ext, target, newMIME = "ppt", "pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"
	}
	input := filepath.Join(dir, "legacy."+ext)
	if err := os.WriteFile(input, content, 0600); err != nil {
		return "", err
	}
	run, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(run, "libreoffice", "-env:UserInstallation=file://"+filepath.Join(dir, "profile"), "--headless", "--convert-to", target, "--outdir", dir, input)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "LC_ALL=C", "HOME="+dir, "XDG_CACHE_HOME="+dir)
	if err := cmd.Run(); err != nil {
		return "", errors.New("legacy Office conversion failed or is unavailable")
	}
	output := filepath.Join(dir, "legacy."+target)
	stat, err := os.Stat(output)
	if err != nil || stat.Size() > 50<<20 {
		return "", errors.New("legacy Office output missing or exceeds limit")
	}
	converted, err := os.ReadFile(output)
	if err != nil {
		return "", err
	}
	return extractOfficeXML(ctx, converted, newMIME)
}
