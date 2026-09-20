package output

import (
	"io"
	"os"
)

// isTerminal reports whether w is an interactive terminal. Implemented against
// os.Stat rather than a dependency: a character device is the distinction that
// matters, and it keeps the module free of a cgo-adjacent term package.
func isTerminal(w io.Writer) bool {
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}
