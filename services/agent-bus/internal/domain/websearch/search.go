package websearch

import (
	"context"
	"errors"
)

var (
	ErrInvalid     = errors.New("local.web_search_invalid")
	ErrUnavailable = errors.New("local.web_search_unavailable")
	ErrLimited     = errors.New("local.web_search_limited")
	ErrTimeout     = errors.New("local.web_search_timeout")
)

type Request struct {
	Query string `json:"query"`
	Limit int    `json:"limit"`
}

type Result struct {
	Title   string `json:"title"`
	URL     string `json:"url"`
	Snippet string `json:"snippet"`
	Date    string `json:"date,omitempty"`
}

type Response struct {
	Results             []Result `json:"results"`
	TimeFilterSupported bool     `json:"time_filter_supported"`
}

type Provider interface {
	Search(context.Context, Request) (Response, error)
}
