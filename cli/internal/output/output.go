// Package output is the CLI's single rendering path. Commands never print;
// they return data through the envelope and this package decides how it looks.
//
// Two rules earn their keep:
//
//   - Breadcrumbs ride on every success. They are the discoverability surface
//     for humans and agents alike, which is why they are structured data and
//     not prose in a help string.
//   - An error is rendered WITHOUT the jq filter. A broken filter must not be
//     able to swallow the message explaining what went wrong.
package output

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/itchyny/gojq"
	"github.com/nauman/rails-conductor/cli/internal/exiterr"
)

// Format is how a result is rendered. It is negotiated once, in the root
// command, not re-decided per command.
type Format string

const (
	FormatAuto     Format = "auto"     // TTY → table, pipe → json
	FormatJSON     Format = "json"     // the envelope, indented
	FormatTable    Format = "table"    // human-readable
	FormatMarkdown Format = "markdown" // portable tables
	FormatQuiet    Format = "quiet"    // data only, no chrome
)

// Breadcrumb is a suggested next command.
type Breadcrumb struct {
	Label   string `json:"label"`
	Command string `json:"command"`
}

// Response is the success envelope.
type Response struct {
	OK          bool           `json:"ok"`
	Data        any            `json:"data,omitempty"`
	Summary     string         `json:"summary,omitempty"`
	Notice      string         `json:"notice,omitempty"`
	Breadcrumbs []Breadcrumb   `json:"breadcrumbs,omitempty"`
	Meta        map[string]any `json:"meta,omitempty"`
}

// ErrorResponse is the failure envelope. Note it is still structured in JSON
// mode — an agent parsing stdout must never receive help text.
type ErrorResponse struct {
	OK    bool           `json:"ok"`
	Error string         `json:"error"`
	Code  string         `json:"code"`
	Hint  string         `json:"hint,omitempty"`
	Meta  map[string]any `json:"meta,omitempty"`
}

// Writer renders envelopes. Out and Err are injected so tests capture them.
type Writer struct {
	Out    io.Writer
	Err    io.Writer
	Format Format
	JQ     string // gojq filter; implies JSON
	IsTTY  bool
}

// New builds a Writer bound to the real process streams.
func New() *Writer {
	return &Writer{Out: os.Stdout, Err: os.Stderr, Format: FormatAuto, IsTTY: isTerminal(os.Stdout)}
}

// Resolve collapses FormatAuto into a concrete format. A jq filter forces JSON,
// because filtering a rendered table is meaningless.
func (w *Writer) Resolve() Format {
	if w.JQ != "" {
		return FormatJSON
	}
	if w.Format != FormatAuto {
		return w.Format
	}
	if w.IsTTY {
		return FormatTable
	}
	return FormatJSON
}

// OK renders a success envelope.
func (w *Writer) OK(resp Response) error {
	resp.OK = true
	switch w.Resolve() {
	case FormatJSON:
		return w.writeJSON(resp)
	case FormatQuiet:
		return w.writeQuiet(resp)
	case FormatMarkdown:
		return w.writeText(resp, true)
	default:
		return w.writeText(resp, false)
	}
}

// Fail renders a failure envelope to stderr and returns the exit code. The jq
// filter is deliberately ignored here (see the package comment).
func (w *Writer) Fail(err error) exiterr.Code {
	code := exiterr.CodeOf(err)
	resp := ErrorResponse{OK: false, Error: err.Error(), Code: code.String(), Hint: exiterr.HintOf(err)}

	format := w.Format
	if format == FormatAuto {
		if w.IsTTY {
			format = FormatTable
		} else {
			format = FormatJSON
		}
	}

	if format == FormatJSON {
		enc := json.NewEncoder(w.Err)
		enc.SetIndent("", "  ")
		_ = enc.Encode(resp)
		return code
	}

	fmt.Fprintf(w.Err, "Error: %s\n", resp.Error)
	if resp.Hint != "" {
		fmt.Fprintf(w.Err, "Hint: %s\n", resp.Hint)
	}
	return code
}

func (w *Writer) writeJSON(resp Response) error {
	if w.JQ == "" {
		enc := json.NewEncoder(w.Out)
		enc.SetIndent("", "  ")
		return enc.Encode(resp)
	}
	return w.writeFiltered(resp)
}

// writeFiltered applies the gojq filter to the envelope. A filter that matches
// nothing prints nothing and is NOT an error — that is how jq behaves, and a
// caller testing for empty output should not also have to handle exit 1.
func (w *Writer) writeFiltered(resp Response) error {
	query, err := gojq.Parse(w.JQ)
	if err != nil {
		return exiterr.Wrap(exiterr.Usage, err, fmt.Sprintf("invalid --jq filter %q", w.JQ),
			"Check the filter syntax; it is jq-compatible.")
	}

	// Round-trip through JSON so gojq sees plain maps/slices, which is the only
	// shape it can walk.
	raw, err := json.Marshal(resp)
	if err != nil {
		return exiterr.Wrap(exiterr.API, err, "could not encode the response", "")
	}
	var input any
	if err := json.Unmarshal(raw, &input); err != nil {
		return exiterr.Wrap(exiterr.API, err, "could not decode the response", "")
	}

	iter := query.Run(input)
	for {
		v, ok := iter.Next()
		if !ok {
			return nil
		}
		if e, isErr := v.(error); isErr {
			return exiterr.Wrap(exiterr.Usage, e, "the --jq filter failed", "Check the filter against the JSON envelope.")
		}
		switch typed := v.(type) {
		case string:
			fmt.Fprintln(w.Out, typed)
		default:
			encoded, err := json.Marshal(v)
			if err != nil {
				return exiterr.Wrap(exiterr.API, err, "could not encode a filtered value", "")
			}
			fmt.Fprintln(w.Out, string(encoded))
		}
	}
}

// writeQuiet prints the data and nothing else — no summary, no breadcrumbs.
func (w *Writer) writeQuiet(resp Response) error {
	if resp.Data == nil {
		return nil
	}
	if s, ok := resp.Data.(string); ok {
		fmt.Fprintln(w.Out, s)
		return nil
	}
	enc := json.NewEncoder(w.Out)
	enc.SetIndent("", "  ")
	return enc.Encode(resp.Data)
}

func (w *Writer) writeText(resp Response, markdown bool) error {
	if resp.Summary != "" {
		fmt.Fprintln(w.Out, resp.Summary)
	}
	if resp.Data != nil {
		if resp.Summary != "" {
			fmt.Fprintln(w.Out)
		}
		if err := w.writeData(resp.Data, markdown); err != nil {
			return err
		}
	}
	if resp.Notice != "" {
		fmt.Fprintf(w.Out, "\n%s\n", resp.Notice)
	}
	if len(resp.Breadcrumbs) > 0 {
		fmt.Fprintln(w.Out, "\nNext:")
		for _, b := range resp.Breadcrumbs {
			fmt.Fprintf(w.Out, "  %-22s %s\n", b.Command, b.Label)
		}
	}
	return nil
}

// writeData renders key/value pairs as aligned text. Richer table rendering
// (lipgloss) is a later slice; this keeps the envelope honest meanwhile.
func (w *Writer) writeData(data any, markdown bool) error {
	raw, err := json.Marshal(data)
	if err != nil {
		return exiterr.Wrap(exiterr.API, err, "could not encode the response", "")
	}
	var asMap map[string]any
	if err := json.Unmarshal(raw, &asMap); err != nil {
		// Not an object — print the JSON rather than inventing a layout.
		var indented strings.Builder
		enc := json.NewEncoder(&indented)
		enc.SetIndent("", "  ")
		if err := enc.Encode(data); err != nil {
			return exiterr.Wrap(exiterr.API, err, "could not encode the response", "")
		}
		fmt.Fprint(w.Out, indented.String())
		return nil
	}

	keys := sortedKeys(asMap)
	if markdown {
		fmt.Fprintln(w.Out, "| Field | Value |")
		fmt.Fprintln(w.Out, "| --- | --- |")
		for _, k := range keys {
			fmt.Fprintf(w.Out, "| %s | %s |\n", k, scalar(asMap[k]))
		}
		return nil
	}
	width := 0
	for _, k := range keys {
		if len(k) > width {
			width = len(k)
		}
	}
	for _, k := range keys {
		fmt.Fprintf(w.Out, "%-*s  %s\n", width, k, scalar(asMap[k]))
	}
	return nil
}

func scalar(v any) string {
	switch typed := v.(type) {
	case nil:
		return "—"
	case string:
		return typed
	case float64:
		if typed == float64(int64(typed)) {
			return fmt.Sprintf("%d", int64(typed))
		}
		return fmt.Sprintf("%g", typed)
	case bool:
		return fmt.Sprintf("%t", typed)
	default:
		encoded, err := json.Marshal(v)
		if err != nil {
			return fmt.Sprintf("%v", v)
		}
		return string(encoded)
	}
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for i := 1; i < len(keys); i++ {
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	return keys
}
