SWITCH ?= hypha-spool
OPAM = opam exec --switch=$(SWITCH) --

PG_TEST_PORT ?= 5439
PG_TEST_URL  ?= postgres://spool:spool@localhost:$(PG_TEST_PORT)/spool
export PG_TEST_PORT

.DEFAULT_GOAL := help
.PHONY: help setup build test lint fmt doc db db-down

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

setup: ## create the switch and install dependencies
	@podman compose version >/dev/null 2>&1 || echo "The tests need podman compose."
	@opam switch list --short | grep -qx $(SWITCH) || opam switch create $(SWITCH) --empty -y
	opam repo add hypha https://github.com/hyphatech/opam-repository.git --switch=$(SWITCH) --rank=1
	opam install . --switch=$(SWITCH) --deps-only --with-test --with-dev-setup -y

build: ## build everything
	$(OPAM) dune build @all

test: db ## run the tests
	SPOOL_TEST_PG=$(PG_TEST_URL) $(OPAM) dune test --force

# Release is the profile opam installs with.
lint: ## check formatting, docs and the release build
	$(OPAM) dune build @all @fmt @doc
	$(OPAM) dune build --profile release @all

fmt: ## format the code
	$(OPAM) dune fmt

doc: ## build the API docs into _build/default/_doc/_html
	$(OPAM) dune build @doc

db: ## start the test database
	podman compose up -d --wait db

db-down: ## stop and delete the test database
	podman compose rm -sf db
