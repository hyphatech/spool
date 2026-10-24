# AGENTS.md

spool is an OCaml library of Hypha Stack: a durable job queue in an
application's own Postgres, for OCaml 5 and Eio. This file is for anyone
changing it, human or agent. Users start at [README.md](README.md).

## Commands

```sh
make setup   # once: the switch hypha-spool, all dependencies
make test    # starts the test Postgres in Podman, runs every test
make lint    # formatting, odoc, and the release build
make fmt     # format in place
```

`make test` needs `podman compose`. Without `SPOOL_TEST_PG` the cases that
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
