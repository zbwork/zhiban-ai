package install

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"sync"
	"time"
)

const (
	// defaultProbeWindow bounds the whole source race; probeBytes is enough to
	// see steady throughput without costing a slow link much.
	defaultProbeWindow = 6 * time.Second
	probeBytes         = 2 << 20
	// probeFloor stops near-instant probes from producing noisy ratios.
	probeFloor = 250 * time.Millisecond
	// officialKeepRatio keeps the first (official) source ahead unless a mirror
	// is more than this many times faster.
	officialKeepRatio = 2.0
)

type probeResult struct {
	reachable   bool
	bytesPerSec float64
}

// rankSources races the candidate sources for a few seconds and returns them
// ordered by measured throughput. The first source (official) keeps its lead
// unless a mirror is clearly faster; unreachable sources go last in their
// original order so the download loop still reports the right failure.
// Integrity is unaffected: every source is still checked against its fixed
// size and SHA-256, so picking a faster mirror never weakens verification.
//
// Motivation: on Chinese home networks GitHub release assets are reachable
// but crawl at tens of KB/s while npm mirrors deliver at tens of MB/s; a
// reachability-only fallback chain never leaves the slow source.
func (d *downloadClient) rankSources(ctx context.Context, sources []Source) []Source {
	if len(sources) < 2 {
		return sources
	}
	window := d.probeWindow
	if window <= 0 {
		window = defaultProbeWindow
	}
	probeCtx, cancel := context.WithTimeout(ctx, window)
	defer cancel()
	results := make([]probeResult, len(sources))
	var wg sync.WaitGroup
	for i := range sources {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = d.probe(probeCtx, sources[i])
		}(i)
	}
	wg.Wait()
	if ctx.Err() != nil {
		return sources
	}
	order := make([]int, len(sources))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(a, b int) bool {
		ra, rb := results[order[a]], results[order[b]]
		if ra.reachable != rb.reachable {
			return ra.reachable
		}
		return ra.bytesPerSec > rb.bytesPerSec
	})
	if results[0].reachable && order[0] != 0 &&
		results[0].bytesPerSec*officialKeepRatio >= results[order[0]].bytesPerSec {
		position := 0
		for i, index := range order {
			if index == 0 {
				position = i
				break
			}
		}
		copy(order[1:position+1], order[:position])
		order[0] = 0
	}
	ranked := make([]Source, len(sources))
	for i, index := range order {
		ranked[i] = sources[index]
	}
	return ranked
}

// probe reads up to probeBytes from source under ctx and reports throughput.
// A source that answers nothing inside the window is unreachable; one that
// answers slowly is reachable with a low rate.
func (d *downloadClient) probe(ctx context.Context, source Source) probeResult {
	var result probeResult
	parsed, err := url.Parse(source.URL)
	fromCatalog := source.Kind == SourceKindZhibanPackage
	if err != nil || d.validateURL(parsed, fromCatalog) != nil {
		return result
	}
	request, err := http.NewRequestWithContext(withCatalogSource(ctx, fromCatalog), http.MethodGet, source.URL, nil)
	if err != nil {
		return result
	}
	request.Header.Set("User-Agent", d.userAgent)
	request.Header.Set("Accept", "application/octet-stream")
	request.Header.Set("Range", fmt.Sprintf("bytes=0-%d", probeBytes-1))
	started := time.Now()
	response, err := d.client.Do(request)
	if err != nil {
		return result
	}
	defer response.Body.Close()
	if (response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent) ||
		d.validateURL(response.Request.URL, fromCatalog) != nil {
		return result
	}
	received, _ := io.Copy(io.Discard, io.LimitReader(response.Body, probeBytes))
	if received <= 0 {
		return result
	}
	elapsed := time.Since(started)
	if elapsed < probeFloor {
		elapsed = probeFloor
	}
	result.reachable = true
	result.bytesPerSec = float64(received) / elapsed.Seconds()
	return result
}
