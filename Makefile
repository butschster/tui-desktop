# acme/starter — initialize, verify, and publish a standalone Kickside module.
MODULE := starter
TYPE   := plugin
VIS    := private
EMBED  := --embed ui_fs

# pipefail lets the test targets both stream runner output and keep its exit
# code while grepping the log afterwards.
SHELL := bash
.SHELLFLAGS := -o pipefail -ec

.PHONY: init setup check build dev lint typecheck test test-pg postgres-up postgres-down verify release-check publish
init:
	node scripts/init-module.mjs --organization "$(ORG)" --module "$(MODULE_NAME)" --title "$(TITLE)" $(if $(NAMESPACE),--namespace "$(NAMESPACE)",) $(if $(TAG),--tag "$(TAG)",) $(if $(GITHUB_OWNER),--github-owner "$(GITHUB_OWNER)",)
setup:
	wippy update
	cd test && wippy update
	npm --prefix ui ci
check:
	node scripts/check-module.mjs
	node scripts/test-initializer.mjs
build:
	npm --prefix ui run build
dev:
	npm --prefix ui run dev
lint:
	wippy lint
typecheck:
	npm --prefix ui run type-check
# The runner exits 0 when it discovers zero tests, which turns a broken
# discovery setup into a false-green run. An empty discovery is always a
# defect here — the template ships suites — so both targets fail on it.
test:
	cd test && wippy test 2>&1 | tee .wippy/last-test-run.log && ! grep -q "No tests found" .wippy/last-test-run.log
test-pg:
	cd test && wippy test --profile postgres 2>&1 | tee .wippy/last-test-run.log && ! grep -q "No tests found" .wippy/last-test-run.log
postgres-up:
	docker compose -f compose.test.yaml up -d --wait
postgres-down:
	docker compose -f compose.test.yaml down -v
verify: setup check lint typecheck build test
release-check: verify
	wippy auth status
	wippy publish --dry-run --create --module-visibility $(VIS) --module-type $(TYPE) $(EMBED)
publish: build
	node scripts/check-module.mjs
	wippy auth status
	wippy publish --create --module-visibility $(VIS) --module-type $(TYPE) $(EMBED)
