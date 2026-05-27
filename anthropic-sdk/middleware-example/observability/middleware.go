// Package observability provides a middleware for the Anthropic Go SDK that
// captures LLM request/response data and reports it to Three.dev.
package observability

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"time"

	"github.com/anthropics/anthropic-sdk-go/option"
	"github.com/google/uuid"
)

// Config holds configuration for the observability middleware.
type Config struct {
	// APIKey is the Three.dev API key (r3_sk_...).
	// Sent as: Authorization: Bearer <APIKey>.
	APIKey string
	// UseCaseSlug is the Three.dev use case identifier.
	UseCaseSlug string
	// Endpoint is the base URL of the Three.dev api3 service.
	// Defaults to "https://api.three.dev". Override only for staging/local instances.
	Endpoint string
}

// NewMiddleware returns an option.Middleware that captures every Bedrock
// request/response and asynchronously reports it to Three.dev.
//
// # Middleware ordering — critical
//
// Register this AFTER bedrock.WithConfig or bedrock.WithLoadDefaultConfig so
// it sits innermost in the chain and sees the Bedrock-transformed request
// (path /model/{model}/invoke). The SDK builds the chain in reverse
// registration order, so "last in the options list" = "innermost".
//
//	client := anthropic.NewClient(
//	    bedrock.WithLoadDefaultConfig(ctx),                         // outermost
//	    option.WithMiddleware(observability.NewMiddleware(cfg)),     // innermost
//	)
func NewMiddleware(cfg Config) option.Middleware {
	if cfg.Endpoint == "" {
		cfg.Endpoint = "https://api.three.dev"
	}

	return func(r *http.Request, next option.MiddlewareNext) (*http.Response, error) {
		var reqBody []byte
		reqBody, r.Body = drainBody(r.Body)

		c := captured{
			requestID:      uuid.Must(uuid.NewV7()).String(),
			startTime:      time.Now(),
			path:           r.URL.Path,
			reqBody:        reqBody,
			reqContentType: r.Header.Get("Content-Type"),
		}

		res, callErr := next(r)
		c.endTime = time.Now()
		c.callErr = callErr

		if callErr == nil && res != nil {
			c.resBody, res.Body = drainBody(res.Body)
			c.statusCode = res.StatusCode
			c.resContentType = res.Header.Get("Content-Type")
		}

		go safeReport(cfg, c)
		return res, callErr
	}
}

// drainBody reads all bytes from rc, closes it, and returns the bytes along
// with a fresh ReadCloser so the body can be read again by the next handler.
func drainBody(rc io.ReadCloser) ([]byte, io.ReadCloser) {
	if rc == nil || rc == http.NoBody {
		return nil, rc
	}
	b, _ := io.ReadAll(rc)
	rc.Close()
	return b, io.NopCloser(bytes.NewReader(b))
}

// captured holds all data extracted from a single request/response cycle.
type captured struct {
	requestID      string
	startTime      time.Time
	endTime        time.Time
	path           string
	statusCode     int
	reqBody        []byte
	resBody        []byte
	reqContentType string
	resContentType string
	callErr        error
}

// apiClient is used for all Three.dev reporting calls. The 10 s timeout keeps
// the goroutine bounded even if the endpoint is slow or unreachable.
var apiClient = &http.Client{Timeout: 10 * time.Second}

// safeReport is the fire-and-forget reporter. All panics and errors are
// swallowed so that reporting failures never affect the calling application.
func safeReport(cfg Config, c captured) {
	defer func() { recover() }() //nolint:errcheck
	reportToAPI(cfg, c)
}

// reportToAPI POSTs the captured event to api3's POST /api/v1/request endpoint.
func reportToAPI(cfg Config, c captured) {
	body := buildPayload(cfg, c)

	req, err := http.NewRequest(http.MethodPost, cfg.Endpoint+"/api/v1/request", bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+cfg.APIKey)

	resp, err := apiClient.Do(req)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body) //nolint:errcheck
}

// recordRequest is the payload sent to api3's POST /api/v1/request.
// provider "amazon_bedrock_runtime" + path "/model/{model}/invoke" is the
// combination that routes to api3's MessagesHandler for structured parsing.
type recordRequest struct {
	ID          string        `json:"id"`
	UseCaseSlug string        `json:"use_case_slug"`
	Provider    string        `json:"provider"`
	Input       recordInput   `json:"input"`
	Output      recordOutput  `json:"output"`
}

type recordInput struct {
	Content     string `json:"content"`
	Path        string `json:"path"`
	ContentType string `json:"content_type,omitempty"`
}

type recordOutput struct {
	Content                 string   `json:"content"`
	StatusCode              int      `json:"status_code"`
	ReceivedAt              string   `json:"received_at"`
	ContentChunksReceivedAt []string `json:"content_chunks_received_at"`
	ContentType             string   `json:"content_type,omitempty"`
}

func buildPayload(cfg Config, c captured) []byte {
	payload := recordRequest{
		ID:          c.requestID,
		UseCaseSlug: cfg.UseCaseSlug,
		Provider:    "amazon_bedrock_runtime",
		Input: recordInput{
			Content:     base64.StdEncoding.EncodeToString(c.reqBody),
			Path:        c.path,
			ContentType: c.reqContentType,
		},
		Output: recordOutput{
			Content:                 base64.StdEncoding.EncodeToString(c.resBody),
			StatusCode:              c.statusCode,
			ReceivedAt:              c.endTime.UTC().Format(time.RFC3339Nano),
			ContentChunksReceivedAt: []string{},
			ContentType:             c.resContentType,
		},
	}

	b, _ := json.Marshal(payload)
	return b
}

