SWITCH ?= spool
OPAM = opam exec --switch=$(SWITCH) --

PG_TEST_PORT ?= 5439
PG_TEST_URL  ?= postgres://spool:spool@localhost:$(PG_TEST_PORT)/spool
export PG_TEST_PORT

DOCS_PORT ?= 4321
# The reference is odoc's, for spool's packages and nothing under them.
REFERENCE = spool spool-dashboard odoc.support

# opam reads a package of this repository that open-opam carries as that
# version, and one it does not carry yet as "dev", so spool-dashboard's
# dependency on spool at its own version is held apart from the rest.
LOCAL = --ignore-constraints-on=deps-of-spool

.DEFAULT_GOAL := help
.PHONY: help setup build test lint fmt dashboard dashboard-check docs docs-serve db db-down release

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

setup: ## create the switch and install dependencies
	@podman compose version >/dev/null 2>&1 || echo "The tests need podman compose."
	@command -v bun >/dev/null 2>&1 || echo "The documentation site and the dashboard's page need Bun 1.3 or later."
	@opam switch list --short | grep -qx $(SWITCH) || opam switch create $(SWITCH) --empty -y
	opam repo add open-opam https://github.com/open-opam/opam-repository.git --switch=$(SWITCH) --rank=1
	opam install . --switch=$(SWITCH) --deps-only --with-test --with-dev-setup -y $(LOCAL)

build: ## build everything
	$(OPAM) dune build @all

test: db ## run the tests
	SPOOL_TEST_PG=$(PG_TEST_URL) $(OPAM) dune test --force

# Release is the profile opam installs with.
lint: dashboard-check ## check formatting, docs, the release build, litany's rules and the dashboard's bundle
	$(OPAM) dune build @all @fmt @doc
	$(OPAM) dune build --profile release @all
	$(OPAM) litany check

fmt: ## format the code
	$(OPAM) dune fmt

dashboard/web/node_modules: dashboard/web/package.json dashboard/web/bun.lock
	cd dashboard/web && bun install --frozen-lockfile
	@touch dashboard/web/node_modules

# The dashboard's page: dune emits its OCaml as .jsx, and Vite bundles it
# into dashboard/assets, which is committed and compiled into the package.
dashboard: dashboard/web/node_modules ## build the dashboard's page into dashboard/assets
	$(OPAM) dune build @dashboard/web/all
	cd dashboard/web && bun --bun vite build --logLevel warn

# The committed bundle is the build of its source: built again, it differs
# in no file and has none more or fewer.
dashboard-check: dashboard
	@git diff --exit-code --stat -- dashboard/assets \
	  && test -z "$$(git ls-files --others --exclude-standard -- dashboard/assets)" \
	  || { git status --short -- dashboard/assets; \
	       echo "dashboard/assets is not the build of dashboard/web: run make dashboard and commit it."; exit 1; }

docs/node_modules: docs/package.json docs/bun.lock
	cd docs && bun install --frozen-lockfile
	@touch docs/node_modules

# odoc's reference from the .mli files, copied in for the site to serve,
# then the site, into _build/docs.
docs: docs/node_modules ## build the documentation site
	$(OPAM) dune build @doc
	rm -rf docs/public/reference
	mkdir -p docs/public/reference
	cd _build/default/_doc/_html && cp -R $(REFERENCE) $(CURDIR)/docs/public/reference/
	chmod -R u+w docs/public/reference
	cd docs && bun --bun astro build

# The built site, as Pages serves it: Pagefind's index exists only in a
# build, and a page served as it changes loads its styles after its text.
docs-serve: docs ## serve the built documentation site
	cd docs && bun --bun astro preview --open --port $(DOCS_PORT)

db: ## start the test database
	podman compose up -d --wait db

db-down: ## stop and delete the test database
	podman compose rm -sf db

release: ## tag VERSION and make its release
	open-opam release $(VERSION)
