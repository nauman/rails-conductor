package exiterr

import (
	"errors"
	"fmt"
	"net/http"
	"testing"
)

// The numbers are a contract: scripts branch on them. This test exists to make
// renumbering a deliberate act rather than a refactor's side effect.
func TestExitCodesAreStable(t *testing.T) {
	for name, pair := range map[string]struct {
		code Code
		want int
	}{
		"ok": {OK, 0}, "api": {API, 1}, "usage": {Usage, 2}, "auth": {Auth, 3},
		"not found": {NotFound, 4}, "forbidden": {Forbidden, 5},
		"rate limit": {RateLimit, 6}, "network": {Network, 7}, "ambiguous": {Ambiguous, 8},
	} {
		if int(pair.code) != pair.want {
			t.Errorf("%s must stay %d, got %d", name, pair.want, int(pair.code))
		}
	}
}

func TestHTTPStatusMapsToExitCode(t *testing.T) {
	cases := []struct {
		status int
		want   Code
	}{
		{http.StatusUnauthorized, Auth},
		{http.StatusForbidden, Forbidden},
		{http.StatusNotFound, NotFound},
		{http.StatusTooManyRequests, RateLimit},
		{http.StatusInternalServerError, API},
		{http.StatusBadRequest, API},
	}
	for _, c := range cases {
		if got := FromHTTPStatus(c.status); got != c.want {
			t.Errorf("HTTP %d: expected %v, got %v", c.status, c.want, got)
		}
	}
}

// An unclassified error must still fail, not pass as success.
func TestUntypedErrorIsAnAPIError(t *testing.T) {
	if got := CodeOf(errors.New("something broke")); got != API {
		t.Errorf("expected API, got %v", got)
	}
	if got := CodeOf(nil); got != OK {
		t.Errorf("nil is success, got %v", got)
	}
}

func TestWrappedErrorsKeepTheirCodeAndCause(t *testing.T) {
	cause := errors.New("dial tcp: refused")
	err := fmt.Errorf("while reading: %w", Wrap(Network, cause, "could not reach Conductor", "Check the URL."))

	if got := CodeOf(err); got != Network {
		t.Errorf("the code must survive wrapping, got %v", got)
	}
	if got := HintOf(err); got != "Check the URL." {
		t.Errorf("the hint must survive wrapping, got %q", got)
	}
	if !errors.Is(err, cause) {
		t.Error("the cause must remain reachable through errors.Is")
	}
}
