MODULE  := github.com/nauman/rails-conductor/cli
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
LDFLAGS := -X $(MODULE)/internal/version.Version=$(VERSION) -X $(MODULE)/internal/version.Commit=$(COMMIT)

.PHONY: build test test-e2e fmt-check vet tidy-check surface-snapshot ci

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
surface-snapshot: build
	@./bin/conductor --help > SURFACE.txt 2>&1 || true
	@for c in status version; do echo "" >> SURFACE.txt; ./bin/conductor $$c --help >> SURFACE.txt 2>&1 || true; done
	@echo "wrote SURFACE.txt"

# One gate. Run it before pushing, not after.
ci: fmt-check vet test test-e2e
	@echo "cli: green"
