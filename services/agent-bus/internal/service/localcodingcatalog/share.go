package localcodingcatalog

// PaaS drive share links stand in for a CDN in front of the platform object
// store (plan §2.1): the store's origin has no CDN (Bus logs cdn=false) and
// mobile networks reach it at about 1 MB/s, while a drive share address
// resolves through the CDN. The Bus generates one share per published
// object-store package and regenerates it well before it expires ("refresh
// early" instead of "extend", so the platform's lifetime cap does not
// matter); the catalog hands the link out only while more validity remains
// than a catalog may live offline, otherwise it falls back to the Bus
// redirect. Integrity is untouched: the signed catalog still carries size
// and SHA-256.

import (
	"bytes"
	"context"
	"crypto/md5" //nolint:gosec // the drive share API mandates MD5 request signing
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
)

const (
	// DefaultShareValidFor is the lifetime requested per generation when the
	// configuration leaves it unset; ops only said the cap is "long".
	DefaultShareValidFor = 365 * 24 * time.Hour
	// ShareRefreshBefore is the remaining validity below which a link is
	// regenerated. It exceeds the catalog TTL so a catalog never carries a
	// link that dies while the catalog itself is still valid offline.
	ShareRefreshBefore = 10 * 24 * time.Hour
	// ShareRefreshInterval is how often the Bus runs RefreshShareLinks.
	ShareRefreshInterval = 10 * time.Minute

	shareRefreshBatch   = 200
	shareRequestTimeout = 30 * time.Second
	sharePath           = "/share/gen"
	shareCodeMaxLen     = 64
)

// ShareConfig configures share link generation; nil disables it.
type ShareConfig struct {
	// APIBaseURL is the drive share service origin (https://pan.yixin.com,
	// http://pan.paas.paas.test); requests go to <APIBaseURL>/share/gen.
	APIBaseURL string
	// PublicHost replaces the host of the returned download address and
	// forces https (production: s3.yixin.com, the only host behind the CDN;
	// pan.yixin.com answers HEAD with 405). Empty keeps the address as
	// returned — a non-https result is stored but never handed out.
	PublicHost string
	// ValidFor is the lifetime requested per generation (minute granularity;
	// DefaultShareValidFor when zero).
	ValidFor time.Duration
	// Project is the share API "name" field; empty derives it from the
	// bucket name up to the first '-' (the PaaS documentation's convention).
	Project string
	// Sharer is the share API "sharer" field (an email address). Required.
	Sharer string
}

// ShareCredentials hands the share client the platform bucket and its key
// pair: the share API signs with the bucket's own AK/SK, so nothing new is
// provisioned. Never logged.
type ShareCredentials func(ctx context.Context) (bucket, accessKeyID, secretAccessKey string, err error)

// ShareRefreshReport is the outcome of one RefreshShareLinks pass.
type ShareRefreshReport struct {
	Candidates int
	Generated  int
	// Failures are operator-facing, one per row that kept its old state:
	// "<target> <version> <uuid>: <reason>". No credentials, no URLs.
	Failures []string
}

// RefreshShareLinks implements Service. One pass: every published
// object-store package whose link is missing or expires within
// ShareRefreshBefore gets a fresh share. Rows that fail keep what they had
// (the catalog falls back to the redirect for them) and are retried next
// tick. Several Bus replicas may run this concurrently; a duplicate share
// for the same object is harmless.
func (s *impl) RefreshShareLinks(ctx context.Context) (*ShareRefreshReport, error) {
	report := &ShareRefreshReport{}
	if s.share == nil || s.shareCreds == nil {
		return report, nil
	}
	rows, err := s.repo.ListShareRefreshCandidates(ctx, s.now().Add(ShareRefreshBefore), shareRefreshBatch)
	if err != nil {
		return nil, err
	}
	report.Candidates = len(rows)
	if len(rows) == 0 {
		return report, nil
	}
	bucket, accessKey, secret, err := s.shareCreds(ctx)
	if err != nil {
		return nil, fmt.Errorf("resolve platform storage credentials: %w", err)
	}
	for _, row := range rows {
		link, err := s.generateShare(ctx, bucket, strings.TrimPrefix(row.StorageURI, "oss://"), accessKey, secret)
		if err != nil {
			report.Failures = append(report.Failures, fmt.Sprintf("%s %s %s: %v", row.TargetID, row.Version, row.UUID, err))
			continue
		}
		if err := s.repo.SetShareLink(ctx, row.UUID, *link); err != nil {
			report.Failures = append(report.Failures, fmt.Sprintf("%s %s %s: record share link: %v", row.TargetID, row.Version, row.UUID, err))
			continue
		}
		report.Generated++
	}
	return report, nil
}

// shareURLFor is the share link the catalog may hand out for v: https only,
// and with more validity left than the catalog TTL, so a catalog cached
// offline for its whole lifetime never points at a dead link.
func (s *impl) shareURLFor(v dom.Version) string {
	if !strings.HasPrefix(v.ShareURL, "https://") {
		return ""
	}
	if v.ShareLinkRemaining(s.now()) <= s.catalogTTL {
		return ""
	}
	return v.ShareURL
}

// generateShare calls POST /share/gen for one object key and turns the
// answer into what the row stores. The share service's own download address
// (data.origin) is kept, with the host swapped for the CDN-fronted one.
func (s *impl) generateShare(ctx context.Context, bucket, key, accessKey, secret string) (*dom.ShareLinkInput, error) {
	cfg := s.share
	validFor := cfg.ValidFor
	if validFor <= 0 {
		validFor = DefaultShareValidFor
	}
	minutes := int64(validFor / time.Minute)
	project := strings.TrimSpace(cfg.Project)
	if project == "" {
		project = shareProjectOf(bucket)
	}
	now := s.now()
	nonce, err := shareNonce()
	if err != nil {
		return nil, err
	}
	params := map[string]string{
		"bucket": bucket, "targetPath": key, "validTime": strconv.FormatInt(minutes, 10),
		"sharer": cfg.Sharer, "name": project, "public": "true",
	}
	body, err := json.Marshal(map[string]any{
		"bucket": bucket, "targetPath": key, "validTime": minutes,
		"sharer": cfg.Sharer, "name": project, "public": true,
	})
	if err != nil {
		return nil, err
	}
	query := url.Values{
		"accessKey": {accessKey},
		"sign":      {shareSign(accessKey, secret, params, now.Unix(), nonce)},
		"timestamp": {strconv.FormatInt(now.Unix(), 10)},
		"nonce":     {nonce},
	}
	ctx, cancel := context.WithTimeout(ctx, shareRequestTimeout)
	defer cancel()
	endpoint := strings.TrimRight(strings.TrimSpace(cfg.APIBaseURL), "/") + sharePath + "?" + query.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, errors.New("share service address invalid")
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "agent-bus/local-coding-share")
	response, err := s.httpClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("share service unreachable: %w", err)
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("share service HTTP %d: read response: %w", response.StatusCode, err)
	}
	var out struct {
		Success bool   `json:"success"`
		Code    int    `json:"code"`
		Message string `json:"message"`
		Data    struct {
			Origin string `json:"origin"`
			URL    string `json:"url"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("share service HTTP %d: response is not JSON", response.StatusCode)
	}
	if response.StatusCode != http.StatusOK || !out.Success || out.Code != http.StatusOK {
		return nil, fmt.Errorf("share service HTTP %d code %d: %s", response.StatusCode, out.Code, strings.TrimSpace(out.Message))
	}
	public, err := publicShareURL(out.Data.Origin, cfg.PublicHost)
	if err != nil {
		return nil, err
	}
	return &dom.ShareLinkInput{Code: shareCodeOf(out.Data.URL, out.Data.Origin), URL: public, ExpiresAt: now.Add(validFor)}, nil
}

// shareSign is the drive platform's request signature:
// md5("<accessKey>:<k=v&… sorted by key, values verbatim>:<timestamp>:<nonce>:<secret>").
func shareSign(accessKey, secret string, params map[string]string, timestamp int64, nonce string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys))
	for _, k := range keys {
		pairs = append(pairs, k+"="+params[k])
	}
	sum := md5.Sum([]byte(accessKey + ":" + strings.Join(pairs, "&") + ":" + strconv.FormatInt(timestamp, 10) + ":" + nonce + ":" + secret)) //nolint:gosec // mandated by the share API
	return hex.EncodeToString(sum[:])
}

func shareNonce() (string, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("share nonce: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// shareProjectOf is the PaaS documentation's default for the "name" field:
// the bucket name up to its first '-' (agent-bus-public-read → agent).
func shareProjectOf(bucket string) string {
	if i := strings.Index(bucket, "-"); i > 0 {
		return bucket[:i]
	}
	return bucket
}

// publicShareURL rewrites the share service's download address onto the
// CDN-fronted host (https); with no host configured it is kept verbatim.
func publicShareURL(origin, publicHost string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(origin))
	if err != nil || parsed.Host == "" || parsed.Path == "" || parsed.Path == "/" {
		return "", errors.New("share service returned no download address")
	}
	if host := strings.TrimSpace(publicHost); host != "" {
		parsed.Host = host
		parsed.Scheme = "https"
	}
	return parsed.String(), nil
}

// shareCodeOf extracts the share code (/s/<code>[/origin]) for display.
func shareCodeOf(candidates ...string) string {
	for _, raw := range candidates {
		parsed, err := url.Parse(strings.TrimSpace(raw))
		if err != nil {
			continue
		}
		code := path.Base(strings.TrimSuffix(parsed.Path, "/origin"))
		if code == "" || code == "." || code == "/" {
			continue
		}
		if len(code) > shareCodeMaxLen {
			code = code[:shareCodeMaxLen]
		}
		return code
	}
	return ""
}
