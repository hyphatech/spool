# spool

[![ci](https://img.shields.io/github/actions/workflow/status/hyphatech/spool/ci.yml?branch=main&label=ci)](https://github.com/hyphatech/spool/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/hyphatech/spool?label=release)](https://github.com/hyphatech/spool/releases)
[![license](https://img.shields.io/github/license/hyphatech/spool)](LICENSE)
![OCaml 5.5+](https://img.shields.io/badge/OCaml-5.5%2B-EC6813?logo=ocaml&logoColor=white)
[![Hypha Stack](https://img.shields.io/badge/Hypha-Stack-d4a820?labelColor=15120e)](https://hyphatech.io/stack/)

A durable job queue in your own Postgres, for OCaml 5 and Eio.

Work that outlives a request, kept where the rest of the application's
state is: a job is a row written in the transaction that made the work
owed, claimed by a runner under a lease, run outside every transaction,
retried with backoff, and finished once in the table however often it was
attempted. It runs over [rowtype](https://github.com/hyphatech/rowtype)'s
Postgres backend and names no driver; `spool.mli` is the reference.

## Install

```sh
opam repo add hypha https://github.com/hyphatech/opam-repository.git
opam install spool
```

```lisp
(libraries spool rowtype-postgres eio_main)
```

## The table

spool keeps its jobs in one table, `spool_jobs`, made by its own
migrations. They are plain SQL, installed with the package in
`share/spool/migrations`, and applied beside your own as a history of
their own, before your application starts:

```sh
rowtype-migrate up --source spool    # spool's migrations, then yours
```

`--source` needs rowtype 0.5.0 or later. An upgrade of spool that changes
the table ships a new migration, and the same command applies it. With
another migration tool, copy the files from
`$(opam var spool:share)/migrations` into its folder: they are plain
Postgres.

A runner checks the table before it starts, and refuses a database where
it is missing or behind, naming the command to run. `Spool.statements` is
every statement the package runs, for `Rowtype_postgres.verify` beside
your own.

Five states, and the rest derived: *scheduled* is `available` with a later
`scheduled_at`, *retrying* is `available` with an attempt made.

## Kinds and enqueueing

```ocaml
(* {"order": "..."} *)
let order =
  Wiretype.Object.map (fun id -> id)
  |> Wiretype.Object.mem "order" Wiretype.string ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt =
  Spool.Kind.make ~queue:"mail" ~timeout:Mtime.Span.min "receipt.send"
    order

(* in the caller's transaction, through its own connection *)
Spool.enqueue conn ~now ~unique:order_id receipt order_id
```

A kind is its name, its payload's `wiretype` description, its queue, its
priority (0 to 9, 0 first), its attempts (20), its timeout (five minutes), its
backoff and whether its rows are kept once completed. Its name is its
identity in the table: a changed payload shape is a new name. Every
instant the queue is given or answers is a `Ptime.t`, the caller's `now`,
and every duration an `Mtime.Span.t` named for what it bounds.

The payload is an object, and `Kind.make` refuses a description of
anything else: each member is named for what it holds, so a row read in the
table says what each value is of -- a bare key names nothing -- and a kind
gains a member, with an `~absent`, without a new name.

`enqueue` writes the row and nothing else, so a rollback leaves no job; a
runner hears of it when the transaction commits. It may run `~at` an
instant, `~after` a span from now, and not after `~expires_at`. A `~unique` key
already waiting in the kind is that job, brought to the earlier instant and
the higher priority: asking twice is one job. A key is unique among waiting
jobs only, so a change made while its job runs is a job of its own.

## A runner

```ocaml
let runner =
  Spool.Runner.create ~sw ~net ~mono_clock ~now
    ~queues:[ ("mail", 2) ]
    [ Spool.handle receipt (fun _job order_id -> send_receipt order_id) ]
    conninfo
in
Spool.Runner.start runner;
(* ... *)
Spool.Runner.stop runner
```

A handler answers `Ok ()`, `Retry reason` (after the kind's backoff),
`Retry_in (span, reason)` (after what an upstream said) or `Discard reason`
(never again, and no attempt used: it cannot succeed however long it
waits). A raise is a retry whose reason names the exception's constructor,
never its argument; the log line carries the rest. An attempt past its
kind's timeout is cancelled and is a failure.

| What | How |
|---|---|
| Claiming | one statement, `for update skip locked`, in a transaction that commits before the handler starts, so runners in several processes claim from one queue without waiting on each other |
| Leases | a claim holds a job until `lease_ends_at`; the heartbeat renews every lease the runner holds every quarter lease, and a runner that cannot renew for three quarters of it stops the job itself |
| Finishing | guarded by the runner and the attempt: a finish from a runner whose lease was taken changes nothing |
| Rescue | every runner's heartbeat makes every lapsed lease available again, its attempt counted, or discarded where it was the last |
| Backoff | 15 s doubled each attempt to at most six hours, spread by a tenth either way: twenty attempts span about two and a half days |
| Waking | `enqueue` notifies the table's channel with the queue's name; the poll is the truth and a notification a hint |
| Expiry | a job past `expires_at` is discarded unrun |
| Pruning | hourly, finished rows older than their retention: a day completed, a fortnight discarded or cancelled |
| Stopping | `stop` claims nothing more, waits a grace for running jobs, then puts back the rest with their attempt not counted |

The runner's connections are its own -- a small pool and a listener --
because one borrowed from the application's would lose its heartbeats
exactly when the application is busiest, and a lost heartbeat is a job run
twice.

`find`, `counts`, `cancel` and `retry` are an operator's hand: a cancelled
waiting job never runs and a cancelled running one is stopped at its
runner's next heartbeat; a retried job is available again from its first
attempt with its reasons kept, unless a job of its kind already waits under
its key, which is then the answer.

## Testing

`Runner.drain` runs every job due at `now ()` through the runner's own
claim and finish, one at a time on the caller's fiber, and answers what
each attempt left the job: a test moves its clock and drains, and nothing
sleeps.

What a job runs is at least once and finished once. A handler whose effect
must happen once is idempotent, or keyed by the job.

## What it does not do yet

- **No periodic jobs.** A schedule that runs once across several processes
  needs a leader or a unique slot per instant; it is the first thing a
  second process asks for.
- **No limits across processes.** Concurrency is per runner: two runners of
  one queue run twice its concurrency, and there is no global rate.
- **No dependencies between jobs**, batches or workflows.
- **No pausing a queue**, and no fairness between keys: one key's many jobs
  run before another's few, in the order the claim reads.
- **A job's lines carry no request id or trace of the enqueuer's.** The
  runner's statements reach the application's observer, but nothing ties a
  job to the request that made it owed.
- **A queue's counts are exported nowhere.** `counts` answers them, and
  nothing turns them into metrics.
- **A handler that never yields cannot be stopped.** A timeout, a lost lease
  and stopping cancel a fiber at its next effect, so a handler busy on the
  CPU without one runs on until it ends.
- **Two clocks that disagree by more than a quarter of a lease** can run one
  job in two places: a lease is an instant from the claiming runner's
  `now`, compared against another's when it rescues.

## Contributing

See [AGENTS.md](AGENTS.md).

## Licence

MIT, copyright Hypha Technologies Ltd. See [LICENSE](LICENSE).
