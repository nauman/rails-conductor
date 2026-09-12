package cli

import (
	"os"
	"strings"
	"testing"

	"github.com/nauman/rails-conductor/cli/internal/commands"
	"github.com/nauman/rails-conductor/cli/internal/output"
	"github.com/spf13/cobra"
)

// A breadcrumb is a promise: follow this and it works. Checking that by hand is
// exactly the kind of thing that rots, so it is checked mechanically.
//
// This walks every breadcrumb any command can emit and asserts the command it
// names is registered on the real tree.
func TestEveryBreadcrumbNamesARegisteredCommand(t *testing.T) {
	root, _ := NewRootCmd(os.Stdout, os.Stderr)

	for _, crumb := range allBreadcrumbs() {
		fields := strings.Fields(crumb.Command)
		if len(fields) == 0 || fields[0] != "conductor" {
			t.Errorf("breadcrumb %q must start with `conductor`", crumb.Command)
			continue
		}
		// Drop the binary name, and any <placeholder> or --flag arguments.
		var path []string
		for _, f := range fields[1:] {
			if strings.HasPrefix(f, "-") || strings.HasPrefix(f, "<") {
				break
			}
			path = append(path, f)
		}
		if len(path) == 0 {
			continue // `conductor` alone is the root; always valid
		}
		if !hasCommandPath(root, path) {
			t.Errorf("breadcrumb %q names a command that does not exist — "+
				"implement it or stop suggesting it", crumb.Command)
		}
	}
}

// allBreadcrumbs collects the breadcrumbs each command emits. New commands add
// their set here; that is cheaper than reflecting over unexported functions.
func allBreadcrumbs() []output.Breadcrumb {
	var all []output.Breadcrumb
	all = append(all, commands.StatusBreadcrumbsForTest()...)
	all = append(all, commands.SituationBreadcrumbsForTest()...)
	all = append(all, commands.AuthBreadcrumbsForTest()...)
	return all
}

func hasCommandPath(root *cobra.Command, path []string) bool {
	current := root
	for _, segment := range path {
		found := false
		for _, child := range current.Commands() {
			if child.Name() == segment {
				current, found = child, true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
