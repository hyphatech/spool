# Changes

## 0.7.0 (2026-11-17)

- A new package, `spool-dashboard`: a live dashboard for the queue, as
  routes of the application's own Spindle server,
  `Spool_dashboard.routes ~operator ~may ~pool ~mono_clock ()` at `/spool`.
  Who may do what is the application's to say, through Spindle's `Access`:
  `operator` is its own user, and `may` allows or denies each
  `Spool_dashboard.action` -- viewing alone, say, for support -- with no
  default; the page shows only what its viewer may do, each action is a
  line on the `spool-dashboard` source, and a live stream ends each
  `?stream_for` (a minute) to be asked for again. It shows counts by state,
  the runners, the queues with a switch to pause each and a form for their
  limits, a chart of attempts finished, the jobs by state, queue and kind
  with a job's attempts, payload and workflow, and the schedules; it
  retries, cancels and deletes a job or a selection, sets a queue's
  limits, and runs a schedule now. Its page is built in, so it installs
  with OCaml alone.
- `Spool.Id.of_string` reads an id back from the text `Spool.Id.to_string`
  wrote.
- Breaking: a job may wait for others, and `Spool.state` has `Blocked` for
  it: `Spool.enqueue_after ~waits_for` writes one, run once every job it
  waits for completed, and cancelled, as everything waiting on it is, once
  one ends otherwise; `Spool.workflow` answers the jobs connected to one.
  `Spool.cancel` cancels what waits on the job, and `Spool.delete` takes
  `~now` to do the same.
- A queue is paused and resumed with `Spool.Queue.pause` and `resume`, kept
  in the table so every runner obeys it; `Spool.Queue.list` answers each.
- `Spool.Runner.list` answers the runners running, each writing its row at
  its heartbeat.
- `Spool.Stats.since` answers what attempts came to, a row a second, queue,
  kind and outcome.
- `Spool.delete` removes a job that is not running, and `Spool.run_again`
  enqueues a copy of any job, its work done again as an operator asks.
- A queue's limits hold across every runner: `Spool.Queue.set_limits`
  bounds how many of its jobs run at once and how many attempts begin in a
  period, for the queue or for each partition of it, as a kind's new
  `~partition` names them, the partitions taken in turns.
- Recurring jobs: `Spool.Schedule.make` enqueues a kind's job at each tick
  of a cron expression read in a named time zone, given to runners with
  `~schedules`; a tick is one job however many runners hold it.
- `Spool.enqueue`'s `~unique_for` holds a key for a period from the
  enqueue, whatever its job's state, its row kept until the period ends.
- `Spool.enqueue_many` writes many jobs of one kind in one statement.
- `Spool.jobs` lists jobs newest first, by state, queue and kind, a page at
  a time; `Spool.info` has the job's payload, and a kind made `~sensitive`
  keeps it from every answer; `Spool.counts ~finished:false` counts what
  waits and runs without reading finished rows; `~finished` finds the jobs
  with an attempt that finished in a span, succeeded, failed or either.
- Spool's new migrations make `spool_queues`, `spool_runners`,
  `spool_stats`, `spool_starts`, `spool_partitions`, `spool_schedules` and
  `spool_dependencies`, and give jobs a partition, a key's period and whether
  they are sensitive: run `rowtype-migrate up
  --source spool` before a runner of this version starts, which refuses a
  database without them.

## 0.6.0 (2026-11-10)

- Breaking: wiretype 0.7 is required.
- spool is published to open-opam, `opam repo add open-opam
  https://github.com/open-opam/opam-repository.git`, and no longer to Hypha's
  opam repository.

## 0.5.1 (2026-11-02)

- rowtype 0.10 is required.

## 0.5.0 (2026-10-25)

- Breaking: rowtype 0.9 is required.

## 0.4.0 (2026-10-19)

- Breaking: wiretype 0.6 is required.

## 0.3.1 (2026-10-16)

- Installs from Hypha's opam repository:
  `opam repo add hypha https://github.com/hyphatech/opam-repository.git`,
  then `opam install spool`. The `pin-depends` are gone: spool takes
  wiretype 0.5 and rowtype 0.8, each up to its next breaking release.

## 0.3.0 (2026-10-14)

- Breaking: spool builds on rowtype 0.8.0, postgres-eio 0.5.0 and
  wiretype 0.5.0. A runner's failures are told by
  `Rowtype_postgres.error_to_string`, as every failure the backend
  answers is, so a connection that could not be made reads as rowtype
  tells it.

## 0.2.0 (2026-10-13)

- Breaking: spool builds on rowtype 0.6.0, postgres-eio 0.4.0 and
  wiretype 0.4.0. The `Rowtype_postgres.Conninfo.t` a runner is given is
  a private record there: one is made by `Conninfo.of_string`, and
  `{ c with database = name }` is `Conninfo.with_database c name`.

## 0.1.0 (2026-10-12)

- The queue, out of the application it was written in: a job is a row
  written in the transaction that made it owed, claimed by a runner under
  a lease, run outside every transaction, retried with backoff and
  finished once, however often it was attempted.
- Its table, `spool_jobs`, is made by spool's own migrations, installed
  with the package and applied with `rowtype-migrate up --source spool`;
  a runner refuses to start on a database where it is missing or behind.
