// Package exiterr is the CLI's error vocabulary: a typed error that carries a
// user-facing hint, and the stable exit-code enum every caller maps onto.
//
// The exit codes are a contract. Scripts and CI branch on them, so a number's
// meaning must never be repurposed — append, never renumber.
package exiterr

import (
	"errors"
	"fmt"
	"net/http"
)

// Code is the process exit status. Values are fixed by GO_CLI_ARCHITECTURE §8.
type Code int

const (
	OK        Code = 0 // success
	API       Code = 1 // generic backend error
	Usage     Code = 2 // bad args or flags
	Auth      Code = 3 // 401 — needs a token
	NotFound  Code = 4 // 404
	Forbidden Code = 5 // 403, or out of scope
	RateLimit Code = 6 // 429
	Network   Code = 7 // connection failure
	Ambiguous Code = 8 // unresolved context
)

// String is for diagnostics and tests, not for users.
func (c Code) String() string {
	switch c {
	case OK:
		return "ok"
	case API:
		return "api"
	case Usage:
		return "usage"
	case Auth:
		return "auth"
	case NotFound:
		return "not_found"
	case Forbidden:
		return "forbidden"
	case RateLimit:
		return "rate_limit"
	case Network:
		return "network"
	case Ambiguous:
		return "ambiguous"
	default:
		return fmt.Sprintf("unknown(%d)", int(c))
	}
}

// Error carries what a user needs to act: what failed, and what to do next.
// Hint is not decoration — an error without a next step makes the user guess.
type Error struct {
	Code Code
	Msg  string
	Hint string
	Err  error
}

func (e *Error) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("%s: %v", e.Msg, e.Err)
	}
	return e.Msg
}

func (e *Error) Unwrap() error { return e.Err }

// New builds a typed error. Hint may be empty when there is genuinely nothing
// to suggest; prefer saying something.
func New(code Code, msg, hint string) *Error {
	return &Error{Code: code, Msg: msg, Hint: hint}
}

// Wrap preserves the cause so errors.Is/As keep working across the boundary.
func Wrap(code Code, err error, msg, hint string) *Error {
	return &Error{Code: code, Msg: msg, Hint: hint, Err: err}
}

// CodeOf reports the exit code for any error. An untyped error is an API error
// rather than a crash: the command still failed, we just did not classify it.
func CodeOf(err error) Code {
	if err == nil {
		return OK
	}
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return API
}

// HintOf returns the actionable hint, if the error carries one.
func HintOf(err error) string {
	var e *Error
	if errors.As(err, &e) {
		return e.Hint
	}
	return ""
}

// FromHTTPStatus is the ONE place HTTP status becomes an exit code. Scattering
// this mapping is how two commands end up disagreeing about what a 403 means.
func FromHTTPStatus(status int) Code {
	switch status {
	case http.StatusUnauthorized:
		return Auth
	case http.StatusForbidden:
		return Forbidden
	case http.StatusNotFound:
		return NotFound
	case http.StatusTooManyRequests:
		return RateLimit
	}
	if status >= 500 || status >= 400 {
		return API
	}
	return OK
}
