package observability

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type failingBody struct {
	data   string
	err    error
	closed bool
}

func (b *failingBody) Read(p []byte) (int, error) {
	n := copy(p, b.data)
	b.data = b.data[n:]
	if len(b.data) == 0 {
		return n, b.err
	}
	return n, nil
}
func (b *failingBody) Close() error { b.closed = true; return nil }

func TestDrainBodyPreservesReadError(t *testing.T) {
	for _, prefix := range []string{"", "partial", `{"ok":true}`} {
		t.Run(prefix, func(t *testing.T) {
			original := &failingBody{data: prefix, err: io.ErrUnexpectedEOF}
			captured, replay := drainBody(original)
			got, err := io.ReadAll(replay)
			if string(captured) != prefix || string(got) != prefix {
				t.Fatalf("bytes changed: captured=%q replay=%q", captured, got)
			}
			if !original.closed {
				t.Fatal("original body was not closed")
			}
			if !errors.Is(err, io.ErrUnexpectedEOF) {
				t.Fatalf("body read error lost: got %v, want unexpected EOF", err)
			}
		})
	}
}

func TestDrainBodySuccessAndEmpty(t *testing.T) {
	captured, replay := drainBody(io.NopCloser(strings.NewReader("complete")))
	got, err := io.ReadAll(replay)
	if err != nil || string(captured) != "complete" || string(got) != "complete" {
		t.Fatalf("unexpected successful replay: %q %q %v", captured, got, err)
	}
	if data, body := drainBody(nil); data != nil || body != nil {
		t.Fatal("nil body changed")
	}
	if data, body := drainBody(http.NoBody); data != nil || body != http.NoBody {
		t.Fatal("NoBody changed")
	}
}

func TestMiddlewarePreservesRequestAndResponseReadErrors(t *testing.T) {
	reporter := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusCreated)
	}))
	defer reporter.Close()
	defer Flush()
	request, err := http.NewRequest(http.MethodPost, "http://example.invalid/model/test/invoke", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Body = &failingBody{data: "request prefix", err: io.ErrUnexpectedEOF}
	middleware := NewMiddleware(Config{Endpoint: reporter.URL})
	response, err := middleware(request, func(r *http.Request) (*http.Response, error) {
		data, readErr := io.ReadAll(r.Body)
		if string(data) != "request prefix" || !errors.Is(readErr, io.ErrUnexpectedEOF) {
			t.Errorf("request read error lost: %q %v", data, readErr)
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header),
			Body: &failingBody{data: "response prefix", err: io.ErrUnexpectedEOF}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	data, readErr := io.ReadAll(response.Body)
	if string(data) != "response prefix" || !errors.Is(readErr, io.ErrUnexpectedEOF) {
		t.Errorf("response read error lost: %q %v", data, readErr)
	}
}
