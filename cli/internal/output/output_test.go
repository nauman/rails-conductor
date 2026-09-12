package output

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/nauman/rails-conductor/cli/internal/exiterr"
)

func newTestWriter(format Format) (*Writer, *bytes.Buffer, *bytes.Buffer) {
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	return &Writer{Out: out, Err: errOut, Format: format}, out, errOut
}

func TestJSONEnvelopeCarriesBreadcrumbs(t *testing.T) {
	w, out, _ := newTestWriter(FormatJSON)
	err := w.OK(Response{
		Data:        map[string]any{"name": "kuickr"},
		Summary:     "1 app",
		Breadcrumbs: []Breadcrumb{{Label: "Deploy it", Command: "conductor deploy kuickr"}},
	})
	if err != nil {
		t.Fatalf("OK returned %v", err)
	}

	var got Response
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatalf("output was not valid JSON: %v", err)
	}
	if !got.OK {
		t.Error("ok must be true on a success envelope")
	}
	if len(got.Breadcrumbs) != 1 || got.Breadcrumbs[0].Command != "conductor deploy kuickr" {
		t.Errorf("breadcrumbs did not survive rendering: %+v", got.Breadcrumbs)
	}
}

func TestJQFilterSelectsFromTheEnvelope(t *testing.T) {
	w, out, _ := newTestWriter(FormatAuto)
	w.JQ = ".data.name"
	if err := w.OK(Response{Data: map[string]any{"name": "kuickr"}}); err != nil {
		t.Fatalf("OK returned %v", err)
	}
	if strings.TrimSpace(out.String()) != "kuickr" {
		t.Errorf("expected the filtered value, got %q", out.String())
	}
}

func TestJQImpliesJSON(t *testing.T) {
	w, _, _ := newTestWriter(FormatAuto)
	w.IsTTY = true // would otherwise resolve to a table
	w.JQ = ".data"
	if got := w.Resolve(); got != FormatJSON {
		t.Errorf("a jq filter must force JSON, got %q", got)
	}
}

// The filter must not be able to hide the reason a command failed.
func TestErrorsIgnoreTheJQFilter(t *testing.T) {
	w, out, errOut := newTestWriter(FormatJSON)
	w.JQ = ".data.nothing.here"

	code := w.Fail(exiterr.New(exiterr.Auth, "no token", "Set CONDUCTOR_MCP_TOKEN."))

	if code != exiterr.Auth {
		t.Errorf("expected the auth exit code, got %v", code)
	}
	if out.Len() != 0 {
		t.Errorf("errors belong on stderr, stdout had %q", out.String())
	}
	var got ErrorResponse
	if err := json.Unmarshal(errOut.Bytes(), &got); err != nil {
		t.Fatalf("error output was not valid JSON: %v", err)
	}
	if got.OK {
		t.Error("ok must be false on an error envelope")
	}
	if got.Error != "no token" || got.Hint == "" {
		t.Errorf("the message and hint must survive: %+v", got)
	}
	if got.Code != "auth" {
		t.Errorf("expected code %q, got %q", "auth", got.Code)
	}
}

func TestAnInvalidFilterIsAUsageError(t *testing.T) {
	w, _, _ := newTestWriter(FormatJSON)
	w.JQ = ".data | ["
	err := w.OK(Response{Data: map[string]any{"a": 1}})
	if err == nil {
		t.Fatal("expected an error for a malformed filter")
	}
	if got := exiterr.CodeOf(err); got != exiterr.Usage {
		t.Errorf("a bad filter is the user's mistake: expected usage, got %v", got)
	}
}

func TestQuietPrintsDataWithoutChrome(t *testing.T) {
	w, out, _ := newTestWriter(FormatQuiet)
	if err := w.OK(Response{
		Data:        map[string]any{"name": "kuickr"},
		Summary:     "a summary nobody asked for",
		Breadcrumbs: []Breadcrumb{{Label: "x", Command: "y"}},
	}); err != nil {
		t.Fatalf("OK returned %v", err)
	}
	got := out.String()
	if strings.Contains(got, "summary") || strings.Contains(got, "Next:") {
		t.Errorf("--quiet must print data only, got %q", got)
	}
	if !strings.Contains(got, "kuickr") {
		t.Errorf("--quiet must still print the data, got %q", got)
	}
}
