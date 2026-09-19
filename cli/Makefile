MODULE  := github.com/nauman/rails-conductor/cli
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
LDFLAGS := -X $(MODULE)/internal/version.Version=$(VERSION) -X $(MODULE)/internal/version.Commit=$(COMMIT)

.PHONY: build test test-e2e fmt-check vet tidy-check surface-snapshot surface-check snapshot check-release ci

build:
	go build -ldflags "$(LDFLAGS)" -o bin/conductor ./cmd/conductor

test:
	go test ./internal/...

test-e2e:
	go test ./e2e/...

fmt-check:
	@test -z "$$(gofmt -l ./cmd ./internal ./e2e)" || { echo "gofmt needed:"; gofmt -l ./cmd ./internal ./e2e; exit 1; }

vet:
	go vet ./...

tidy-check:
	@cp go.mod go.mod.bak && cp go.sum go.sum.bak 2>/dev/null || true
	@go mod tidy
	@diff -q go.mod go.mod.bak >/dev/null || { echo "go mod tidy changed go.mod"; mv go.mod.bak go.mod; exit 1; }
	@rm -f go.mod.bak go.sum.bak

# SURFACE.txt makes a change to the command surface reviewable in a diff, instead
# of something a reader has to notice.
#
# The command list is DISCOVERED, not hardcoded. The first version listed them by
# hand, so renaming `status` to `fleet` left it snapshotting a command that no
# longer existed — and `|| true` swallowed the error, writing a help failure into
# the file and calling it a surface. A snapshot that records its own errors is
# worse than none: it looks maintained.
surface-snapshot: build
	@./bin/conductor --help > SURFACE.txt
	@for c in $$(./bin/conductor --help | awk '/^Available Commands:/{f=1;next} /^$$/{f=0} f{print $$1}' \
	    | grep -vE '^(help|completion)$$'); do \
	  echo "" >> SURFACE.txt; \
	  ./bin/conductor $$c --help >> SURFACE.txt; \
	done
	@echo "wrote SURFACE.txt"

# Fails when the committed snapshot no longer matches the binary. This is the
# check that makes SURFACE.txt worth committing at all.
surface-check: build
	@cp SURFACE.txt .SURFACE.expected
	@$(MAKE) --no-print-directory surface-snapshot >/dev/null
	@if ! diff -q SURFACE.txt .SURFACE.expected >/dev/null; then \
	  echo "SURFACE.txt is stale — the command surface changed. Review the diff and commit it:"; \
	  diff .SURFACE.expected SURFACE.txt || true; \
	  mv .SURFACE.expected SURFACE.txt; \
	  exit 1; \
	fi
	@rm -f .SURFACE.expected

# A full multi-platform build without publishing. Use it to check a release will
# work BEFORE tagging, because a tag is the one part that is awkward to undo.
snapshot:
	CLI_VERSION=$(patsubst v%,%,$(VERSION)) goreleaser build --snapshot --clean

check-release:
	CLI_VERSION=0.0.0 goreleaser check

# One gate. Run it before pushing, not after.
# Releases run this too (bin/release-cli and the hosted workflow both call it),
# so there is one standard for the artifact rather than two.
ci: fmt-check vet tidy-check test test-e2e check-release surface-check
	@echo "cli: green"
