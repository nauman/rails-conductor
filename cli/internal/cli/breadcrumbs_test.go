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
	root, _ := NewRootCmd(os.Stdout, os.Stderr, nil)

	for _, crumb := range allBreadcrumbs() {
		fields := strings.Fields(crumb.Command)
		if len(fields) == 0 || fields[0] != "conductor" {
			t.Errorf("breadcrumb %q must start with `conductor`", crumb.Command)
			continue
		}
		// Drop the binary name and any flags; what remains is a command path
		// followed by arguments. A concrete argument (`server 7`) looks exactly
		// like a subcommand name, so the walk stops at the first segment that is
		// not a registered child rather than assuming every word is a command.
		var segments []string
		for _, f := range fields[1:] {
			if strings.HasPrefix(f, "-") {
				break
			}
			segments = append(segments, f)
		}
		if len(segments) == 0 {
			continue // `conductor` alone is the root; always valid
		}
		if !resolvesToACommand(root, segments) {
			t.Errorf("breadcrumb %q names a command that does not exist — "+
				"implement it or stop suggesting it", crumb.Command)
		}
	}
}

// allBreadcrumbs collects the breadcrumbs each command emits. New commands add
// their set here; that is cheaper than reflecting over unexported functions.
func allBreadcrumbs() []output.Breadcrumb {
	var all []output.Breadcrumb
	all = append(all, commands.FleetBreadcrumbsForTest()...)
	all = append(all, commands.SituationBreadcrumbsForTest()...)
	all = append(all, commands.AuthBreadcrumbsForTest()...)
	all = append(all, commands.ServerBreadcrumbsForTest()...)
	return all
}

// resolvesToACommand walks as deep as the segments match registered commands and
// treats whatever remains as arguments. It requires the FIRST segment to match —
// that is the part a breadcrumb is actually promising.
//
// Remaining segments are checked against the command's own Args validator, so a
// breadcrumb that passes an argument to a command taking none is still caught.
func resolvesToACommand(root *cobra.Command, segments []string) bool {
	current := root
	matched := 0
	for _, segment := range segments {
		child := findChild(current, segment)
		if child == nil {
			break
		}
		current, matched = child, matched+1
	}
	if matched == 0 {
		return false
	}

	remaining := segments[matched:]
	if current.Args == nil {
		return len(remaining) == 0 // cobra's default rejects unknown subcommands
	}
	return current.Args(current, remaining) == nil
}

func findChild(parent *cobra.Command, name string) *cobra.Command {
	for _, child := range parent.Commands() {
		if child.Name() == name {
			return child
		}
	}
	return nil
}
