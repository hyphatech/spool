# The opam switch is local (./_opam), so OCaml commands go through opam exec.
OPAM = opam exec --switch=$(CURDIR) --
# A worktree is nested inside the checkout, and dune would otherwise take the
# outermost dune-project for its root and build the checkout instead.
export DUNE_ROOT := $(CURDIR)

PG_TEST_PORT ?= 5439
PG_TEST_URL  ?= postgres://spool:spool@localhost:$(PG_TEST_PORT)/spool
export PG_TEST_PORT

.DEFAULT_GOAL := help
.PHONY: help setup build test lint fmt doc db db-down

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

setup: ## create the local switch and install dependencies
	@docker compose version >/dev/null 2>&1 || echo "The tests need docker compose."
	@[ -d _opam ] || opam switch create . 5.5.1 --no-install -y
	opam install . --switch=$(CURDIR) --deps-only --with-test --with-dev-setup -y

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
	docker compose up -d --wait db

db-down: ## stop and delete the test database
	docker compose rm -sf db
