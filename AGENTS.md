# AGENTS.md

spool is an OCaml library of Hypha Stack: a durable job queue in an
application's own Postgres, for OCaml 5 and Eio. This file is for anyone
changing it, human or agent. Users start at [README.md](README.md) and the
documentation site, [docs/](docs/src/content/docs/index.mdx).

## Commands

```sh
make setup   # once: the switch spool, all dependencies
make test    # starts the test Postgres in Podman, runs every test
make lint    # formatting, odoc, the release build, litany, and the dashboard's bundle rebuilt and compared
make fmt     # format in place
make dashboard  # the dashboard's page built into dashboard/assets, to commit
make docs    # the documentation site into _build/docs, as Pages publishes it; docs-serve serves it
make release VERSION=1.2.3  # tag and release
```

`make test` needs `podman compose`, and `make docs`, `make dashboard` and
so `make lint` Bun 1.3 or later.
Without `SPOOL_TEST_PG` the cases that need a server are skipped, and the
test output says so. CI runs `make lint` and `make test` on OCaml 5.5.
`docs.yml` publishes the site to GitHub Pages on every push to `main`.

## Layout

```
src/
  spool          the queue: the table's statements, kinds, enqueueing, the
                 runner, its leases, retries and pruning, and drain for tests
migrations/      the table's migrations, plain SQL, installed with the package
                 in share/spool/migrations; the tests make their table from
                 them
docs/            the documentation site, a Starlight site in Hypha's look, from
                 starlight-theme-hypha: its pages in src/content/docs/, every
                 example imported from examples/ with Vite's ?raw into
                 Starlight's <Code>, and
                 built into _build/docs, which dune clean removes
dashboard/       spool-dashboard, its own package over spool, spindle and
                 rowtype-postgres
  spool_dashboard  the routes, each asking the application's operator check
                 first
  wire           what they read and answer, as wiretype descriptions
  live           the live state: one reader a process, sending what changed
  bundle         dashboard/assets made a module by ocaml-crunch as it builds
  assets/        the page as Vite built it, committed
  web/           the page's source: OCaml on solidtype and its HeroUI, rhp's
                 chart, dressed in Hypha's theme by themes/hypha.css over
                 HeroUI's tokens, its fonts bundled; printer/ prints its
                 client from the routes, and Vite bundles what Melange emits
                 into assets/
  test/          the routes in-process against a real Postgres: who may do
                 what, sensitive payloads, paging, actions, the live stream
examples/        the programs the site shows, each built, and run against a
                 Postgres by hand
test/
  test_spool     the queue against a real Postgres: claims, leases taken
                 mid-job, renewals that hang, listeners killed, payloads kept
                 out of every log line
  db_target      a database of a case's own, from SPOOL_TEST_PG
  test_docs      every example on a page
```

How to use it is the documentation site, every example imported from
`examples/` whole: a user-visible change updates its page there.

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
- **A queue's global settings live in its row; a runner's concurrency in
  its code.** One number every runner obeys has one place, where two
  deploys cannot disagree on it, and what one machine carries is that
  machine's. Symptom: a pause or a limit read from `Runner.create`'s
  arguments; the suite pauses a queue and finds no runner claims from it,
  one made after the pause among them.
- **A limit holds across runners, counted under the queue's lock.** A
  limited queue's claim takes the queue's advisory lock and counts what
  runs and what began in the rate's period before it claims, since a limit
  two runners can each half-obey is no limit. Symptom: the suite runs two
  runners on a queue limited to two and sees a third run.
- **A tick is enqueued once, by the transaction that moves the schedule
  past it.** The update of `next_at` is guarded by the value the runner
  read, so of every runner holding a schedule one enqueues each tick, with
  no leader to elect or fail over. Symptom: two jobs of one schedule for
  one tick; the suite holds one schedule in three runners and counts.
- **Every instant is the caller's `now`.** No statement reads the
  database's clock and no wait reads the wall's. Symptom: a test that
  sleeps for a backoff.
- **A job's payload has no log level.** No line, at any level, carries
  it, and a raise's recorded reason is its constructor. Symptom: a secret
  in a log at `debug`; the suite enqueues one and searches every line.
- **A sensitive kind's payload reaches no answer.** A kind made
  `~sensitive` keeps it from every answer, the dashboard's among them: each
  read returns NULL for it in SQL, so no caller of spool's can show it,
  and the dashboard shows it hidden. Symptom: the secret in an answer;
  `test_spool` enqueues one and searches every read, and `test_dashboard`
  every route's answer, the live stream's included.
- **The dashboard writes only through spool's public functions.** It
  cancels, retries, deletes, pauses and runs now by `Spool.cancel` and its
  siblings, and reads by `Spool.jobs` and theirs, so whatever it can do,
  code can, under the same checks. Symptom: `spool_jobs`, or any table or
  SQL, named in `dashboard/`.
- **The dashboard has no route without the application's check.** Every
  route of `Spool_dashboard.routes` asks the application's `may`, through
  `Spindle.Access.require`, for its own action before it reads or does
  anything, and there is no default, since the dashboard cancels and
  deletes and an open default is how it ends up public; who the operator
  is and what they may do stay the application's, so the dashboard keeps
  no users of its own. Symptom: a route answering a request `may` denies,
  or one `Spindle.Access.unguarded` lists; `test_dashboard` asks every
  route the app lists as a stranger and as a viewer, and fails on one it
  does not ask.
- **A live stream ends, and is asked for again.** It is one request, asked
  once, so it lasts `stream_for` and the page opens the next, since access
  the application takes away must reach a page left open. Symptom: a
  stream still sending after its time; `test_dashboard` times one.
- **The committed bundle is the build of its source.** `dashboard/assets/`
  is what `make dashboard` builds from `dashboard/web/`, committed so opam
  installs the package with OCaml alone, and never edited by hand. Symptom:
  `make lint`, which builds it again, finds a file that differs, or one
  more or fewer.
- **The queue names no driver.** It runs over `rowtype-postgres`, which
  hands it a listener as it hands it a pool, so a second backend is a
  second adapter. Symptom: `postgres-eio` named in `src/` or in its
  `dune`.
- **`invalid_arg` is a constant's alone**: `Kind.make`'s, for a name, a
  priority, attempts or a timeout out of range, or a payload that is not an
  object; `Schedule.make`'s, for an expression or a zone that can never
  run; and the dashboard page's entry, built without the element it draws
  in -- each a constant written in source or a build. Symptom: `make
  lint`'s litany reports `restricted-dependency` outside `src/spool.ml`
  and `dashboard/web/src/main.ml`.
