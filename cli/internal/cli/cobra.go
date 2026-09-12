package cli

import (
	"io"
	"os"

	"github.com/spf13/cobra"
)

// cobraCommand aliases cobra's type so root.go reads without the package
// prefix on every line, and so a future framework swap has one seam.
type cobraCommand = cobra.Command

func newCommand(use, short string) *cobra.Command {
	return &cobra.Command{Use: use, Short: short}
}

func isTTY(w io.Writer) bool {
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
