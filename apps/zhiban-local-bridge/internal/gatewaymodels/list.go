// Package gatewaymodels reads the model ids a gateway key may use, from the
// relay's OpenAI-style GET {base_url}/models (contract §2.7.2 "模型选择"). The
// relay's group configuration is the only source of the list: Zhiban keeps no
// model list of its own.
package gatewaymodels

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	requestTimeout = 5 * time.Second
	maxBodyBytes   = 4 << 20
	maxModelIDLen  = 200
)

var (
	ErrUnavailable = errors.New("gatewaymodels: model list unavailable")
	ErrInvalid     = errors.New("gatewaymodels: invalid model list")
)

// List returns the distinct model ids of GET {baseURL}/models, in response order.
func List(ctx context.Context, client *http.Client, baseURL, token string) ([]string, error) {
	base, err := url.Parse(strings.TrimRight(strings.TrimSpace(baseURL), "/"))
	if err != nil || base.Scheme != "https" || base.Host == "" || strings.TrimSpace(token) == "" || client == nil {
		return nil, ErrUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, base.String()+"/models", nil)
	if err != nil {
		return nil, ErrUnavailable
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return nil, ErrUnavailable
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, ErrUnavailable
	}
	var body struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, maxBodyBytes)).Decode(&body); err != nil {
		return nil, ErrInvalid
	}
	seen := make(map[string]struct{}, len(body.Data))
	ids := make([]string, 0, len(body.Data))
	for _, item := range body.Data {
		id := strings.TrimSpace(item.ID)
		if id == "" || len(id) > maxModelIDLen {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return nil, ErrInvalid
	}
	return ids, nil
}
