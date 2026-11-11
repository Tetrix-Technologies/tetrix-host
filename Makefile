# Tetrix Host. Run "make" for the list of targets.
.PHONY: help build install test interop vectors cross app relay-test docs dist install-test release clean

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | expand -t 14

build: ## Build dist/tetrix-host
	go build -trimpath -o dist/tetrix-host ./cmd/tetrix-host

install: build ## Install the tetrix-host command from this checkout
	sh install.sh --binary dist/tetrix-host

test: ## Run the Go tests with the race detector, and the Swift tests
	go vet ./...
	go test -race ./...
	swift test

interop: ## Run the Swift client against the Go host through a relay
	scripts/interop.sh

vectors: ## Rewrite the handshake vectors after a deliberate protocol change
	go test ./internal/secure -run TestVectors -update

cross: ## Build for Linux and Windows, to check that both compile
	GOOS=linux GOARCH=amd64 go build -o /dev/null ./cmd/tetrix-host
	GOOS=linux GOARCH=arm64 go build -o /dev/null ./cmd/tetrix-host
	GOOS=windows GOARCH=amd64 go build -o /dev/null ./cmd/tetrix-host

app: ## Generate the Xcode project and build the Mac app
	xcodegen generate
	xcodebuild -project TetrixHost.xcodeproj -scheme TetrixHost -configuration Debug -derivedDataPath .build/xcode build

relay-test: ## Test the Cloudflare Worker relay, run locally, with the Go relay's tests and the interop run
	cd deploy/cloudflare && npm ci --no-audit --no-fund
	cd deploy/cloudflare && (./node_modules/.bin/wrangler dev --local --port 18950 --ip 127.0.0.1 >/dev/null 2>&1 & echo $$! > .wrangler-dev.pid)
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do curl -s -m 2 http://127.0.0.1:18950/healthz >/dev/null && break; sleep 1; done
	TETRIX_HOST_TEST_RELAY=ws://127.0.0.1:18950 go test -count=1 ./internal/relay; status=$$?; \
	if [ $$status -eq 0 ]; then RELAY_URL=ws://127.0.0.1:18950 scripts/interop.sh; status=$$?; fi; \
	kill $$(cat deploy/cloudflare/.wrangler-dev.pid) 2>/dev/null; rm -f deploy/cloudflare/.wrangler-dev.pid; exit $$status

docs: ## Serve the docs as a site on 127.0.0.1:4786
	node tools/docs-site/serve.mjs

dist: ## Build the release archives in dist/release: make dist VERSION=0.1.0
	scripts/dist.sh $(VERSION)

install-test: ## Test install.sh against a release built here. BREW=1 also installs the formula with Homebrew
	scripts/test-install.sh $(if $(BREW),--brew)

release: ## Publish a release: make release VERSION=0.1.0. DRY_RUN=1 stops before anything is published
	scripts/release.sh $(VERSION) $(if $(DRY_RUN),--dry-run)

clean: ## Delete build output
	rm -rf dist .build
