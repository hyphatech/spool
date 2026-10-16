# AGENTS.md

The spool library is a durable job queue in an application's own Postgres,
for OCaml 5 and Eio. This file is for anyone changing it, human or agent.
Users start at [README.md](README.md).

## Commands

```sh
make setup   # once: the switch hypha-spool, all dependencies
make test    # starts the test Postgres in Docker, runs every test
make lint    # formatting, odoc, and the release build
make fmt     # format in place
```

`make test` needs `docker compose`. Without `SPOOL_TEST_PG` the cases that
need a server are skipped, and the test output says so. CI runs
`make lint` and `make test` on OCaml 5.5.

## Layout

```
src/
  spool          the queue: the table's statements, kinds, enqueueing, the
                 runner, its leases, retries and pruning, and drain for tests
migrations/      the table's migrations, plain SQL, installed with the package
                 in share/spool/migrations; the tests make their table from
                 them
test/
  test_spool     the queue against a real Postgres: claims, leases taken
                 mid-job, renewals that hang, listeners killed, payloads kept
                 out of every log line
  db_target      a database of a case's own, from SPOOL_TEST_PG
```

The module's contract is its `.mli`. Read `src/spool.mli` before changing
it.

## Rules that must hold

Each an instruction, its reason in a clause, and the way you will find out
you broke it. Cite an entry by its bold phrase.

- **A job is claimed, run and finished in three transactions, and the work
  is in none of them.** A claim held open holds a connection and a row for
  as long as the work. Symptom: the runner's pool exhausted by long jobs;
  `test_spool` runs more jobs at once than the pool has
  connections.
- **A finish counts only under its lease, and a lease is renewed or its job
  stopped.** Finishing is guarded by runner and attempt, and a runner that
  cannot renew stops the job a quarter of a lease before it ends -- from a
  watchdog that asks the database nothing, since the renewal is what may
  hang -- so a job runs in two places only when a runner stalls past its own
  lease or two clocks disagree by more than that quarter. Symptom: a job
  completed twice; the suite takes a lease from a runner mid-job, and locks
  a job's row so its renewal hangs.
- **The table is the queue and memory is a cache.** What a runner holds --
  its running set, its wake-ups -- is rebuilt from the table, a notification
  is a hint polling makes good, and a runner killed loses nothing but its
  leases' remaining time. Symptom: a job that runs only if a notification
  arrived; the suite kills the listener's connection, and a runner without
  `stop`.
- **Every instant is the caller's `now`.** No statement reads the
  database's clock and no wait reads the wall's. Symptom: a test that
  sleeps for a backoff.
- **A job's payload has no log level.** No line, at any level, carries
  it, and a raise's recorded reason is its constructor. Symptom: a secret
  in a log at `debug`; the suite enqueues one and searches every line.
- **The queue names no driver.** It runs over `rowtype-postgres`, which
  hands it a listener as it hands it a pool, so a second backend is a
  second adapter. Symptom: `postgres-eio` named in `src/` or in its
  `dune`.
- **No partial functions, and `invalid_arg` only where the `.mli` says it
  raises**: `Kind.make`, for a name, a priority, attempts or a timeout
  out of range, or a payload that is not an object, since a kind is a
  constant written in source. A stdlib call that raises -- `String.sub`, an
  index, `Hashtbl.find`, `List.assoc`, `int_of_string`, `Char.chr`,
  `List.combine` -- is made only on an input already known to be in range,
  and otherwise its `_opt` is.

## House style

The house style, the OCaml checklist and the OCaml tools are
[OCAML.md](OCAML.md), the same in every Hypha OCaml repository and changed
in all of them together, never in one. It is imported here, so it is read
with this file:

@OCAML.md

## Git

How work becomes a commit -- its format, where it happens, what is pushed
-- is [GIT.md](GIT.md), the same in every Hypha repository and changed in
all of them together, never in one. It is imported here, so it is read
with this file:

@GIT.md

## Changes

- A user-visible change adds a line under `## Unreleased` in
  [CHANGES.md](CHANGES.md), in the same commit. A breaking one says so.
- A change that makes a sentence in a document false edits that sentence in
  the same commit.
- A user-visible change updates the `.mli` it touches; a new supported
  feature or a removed limitation updates the README.

## Releases

[Semantic Versioning 2.0.0](https://semver.org). Before 1.0, a breaking
change bumps the minor version and anything else the patch; from 1.0, a
breaking change waits for the next major version, an addition bumps the
minor and a fix the patch.

Breaking means code that follows these rules may stop compiling or behave
differently: removing or renaming anything in an `.mli`, changing a type,
adding a required argument, or changing a default or documented behaviour.
Adding a function, a module, an optional argument or a constructor to a
public variant is not breaking: a variant grows in a minor version, so a
match on one that must compile across versions ends in a catch-all arm. Nor
is the wording of an error or a log line.

The version lives only in the git tag (`0.1.0`, no `v`). A release renames
`## Unreleased` in CHANGES.md to the version and date, and tags it. The GitHub
release notes are that entry with each paragraph and bullet on one line,
since GitHub keeps every line break in release notes. A release is
pushed first and tagged only once CI is green on the commit the tag
names: a broken build is never tagged.

Publishing the GitHub release runs `.github/workflows/release.yml`, which
uploads the source archive to it and publishes the release to Hypha's
opam repository, `hyphatech/opam-repository`, where users install it from
once that repository's CI has installed it. A published version never
changes; running the workflow by hand with a tag publishes a release
that missed it.
