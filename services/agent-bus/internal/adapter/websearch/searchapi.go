package websearch

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/websearch"
)

// SearchAPI holds server configuration only; neither endpoint nor key comes from tool input.
type SearchAPI struct {
	endpoint, key string
	client        *http.Client
}

// New accepts HTTPS endpoints. directHTTP optionally names the one deployment-approved
// intranet endpoint that may use plain HTTP without a proxy; it is never caller-selected.
func New(endpoint, key string, directHTTP ...string) *SearchAPI {
	u, err := url.Parse(endpoint)
	internal := len(directHTTP) > 0 && directHTTP[0] != "" && endpoint == directHTTP[0]
	if err != nil || (!internal && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		endpoint = ""
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if internal {
		transport.Proxy = nil
	}
	return &SearchAPI{endpoint: endpoint, key: strings.TrimSpace(key), client: &http.Client{
		Transport:     transport,
		Timeout:       20 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
}

func (s *SearchAPI) Search(ctx context.Context, in dom.Request) (dom.Response, error) {
	if s.endpoint == "" || s.key == "" {
		return dom.Response{}, dom.ErrUnavailable
	}
	// The upstream currently fixes Google num at 10. Apply caller limit locally.
	body, _ := json.Marshal(map[string]any{"engine": "google", "q": in.Query, "hl": "zh-CN", "num": 10, "no_cache": true})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.endpoint, bytes.NewReader(body))
	if err != nil {
		return dom.Response{}, dom.ErrUnavailable
	}
	req.Header.Set("Authorization", "Bearer "+s.key)
	req.Header.Set("Content-Type", "application/json")
	res, err := s.client.Do(req)
	if err != nil {
		var timeout net.Error
		if errors.As(err, &timeout) && timeout.Timeout() {
			return dom.Response{}, dom.ErrTimeout
		}
		return dom.Response{}, dom.ErrUnavailable
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusTooManyRequests {
		return dom.Response{}, dom.ErrLimited
	}
	if res.StatusCode != http.StatusOK && res.StatusCode != http.StatusBadRequest {
		return dom.Response{}, dom.ErrUnavailable
	}
	const maxBody = 1 << 20
	data, err := io.ReadAll(io.LimitReader(res.Body, maxBody+1))
	if err != nil || len(data) > maxBody {
		return dom.Response{}, dom.ErrUnavailable
	}
	if res.StatusCode == http.StatusBadRequest {
		// The company gateway also encodes an empty Google result as this specific 400.
		// Do not turn other request/auth/provider errors into successful empty searches.
		var empty struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		}
		if json.Unmarshal(data, &empty) == nil && empty.Code == http.StatusBadRequest && empty.Message == "Google didn't return any results." {
			return dom.Response{Results: []dom.Result{}}, nil
		}
		return dom.Response{}, dom.ErrUnavailable
	}
	var raw struct {
		Error    json.RawMessage `json:"error"`
		Metadata struct {
			Status string `json:"status"`
		} `json:"search_metadata"`
		Results *[]struct {
			Title   string `json:"title"`
			Link    string `json:"link"`
			Snippet string `json:"snippet"`
			Date    string `json:"date"`
		} `json:"organic_results"`
	}
	if json.Unmarshal(data, &raw) != nil || (len(raw.Error) > 0 && string(raw.Error) != "null" && string(raw.Error) != `""`) || !strings.EqualFold(raw.Metadata.Status, "Success") {
		return dom.Response{}, dom.ErrUnavailable
	}
	out := dom.Response{Results: make([]dom.Result, 0, in.Limit)}
	// This provider omits organic_results for successful queries without web matches.
	if raw.Results == nil {
		return out, nil
	}
	seen := make(map[string]bool)
	for _, row := range *raw.Results {
		link := strings.TrimSpace(row.Link)
		u, err := url.Parse(link)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" || u.User != nil || len(link) > 2048 || seen[link] {
			continue
		}
		seen[link] = true
		out.Results = append(out.Results, dom.Result{Title: bounded(row.Title, 200), URL: link, Snippet: bounded(row.Snippet, 1000), Date: bounded(row.Date, 100)})
		if len(out.Results) >= in.Limit {
			break
		}
	}
	if len(*raw.Results) > 0 && len(out.Results) == 0 {
		return dom.Response{}, dom.ErrUnavailable
	}
	return out, nil
}

func bounded(s string, limit int) string {
	runes := []rune(strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)))
	if len(runes) > limit {
		runes = runes[:limit]
	}
	return string(runes)
}
