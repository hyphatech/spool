# Getting Started

Durable jobs for modern OCaml, backed by Postgres.

spool is a durable job queue for OCaml, kept in Postgres. A job is a row
written in the transaction that made the work owed, so a rollback leaves no
job. Runners in several processes claim jobs without waiting on each other,
under leases a heartbeat renews, and a lapsed one is rescued. A handler
retries with backoff, retries after what an upstream said, or discards; a
unique key folds a second request into the job already waiting; and a test
runs every job due at its own clock, never sleeping.

A queue's limits hold across every runner -- how many run at once, how many
begin in a period, for each customer apart -- and a queue is paused from the
table. A schedule enqueues a job each tick of a cron expression in a named
time zone, once however many runners hold it; a job may wait for others and
run once they have all completed; and `spool-dashboard` watches and steers it
all from a page of your own Spindle server.

```ocaml title="receipt.ml"
(* An order's receipt: its kind, the order taken with its receipt owed in
   one transaction, and a runner that sends it. quick_start.ml runs it. *)

open Result.Syntax
module Pg = Rowtype_postgres

let send_receipt order =
  Printf.printf "Receipt for order %d sent.\n%!" order;
  Ok ()

(* {"order": 42} *)
let order =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem "order" Wiretype.int ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt = Spool.Kind.make ~queue:"mail" "receipt.send" order

let insert_order =
  Rowtype.find ~params:Rowtype.text ~row:Rowtype.int
    "insert into orders (email) values ($1) returning id"

(* The order and its receipt, in one transaction: a rollback leaves neither. *)
let take_order conn ~now email =
  Pg.Transaction.within conn @@ fun conn ->
  let* order = Pg.run conn insert_order email in
  Spool.enqueue conn ~now ~unique:(string_of_int order) receipt order

let runner ~sw env conninfo =
  Spool.Runner.create ~sw ~net:(Eio.Stdenv.net env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~now:Ptime_clock.now
    ~queues:[ ("mail", 2) ]
    [ Spool.handle receipt (fun _job order -> send_receipt order) ]
    conninfo
```

## Install

It needs opam, with a switch of OCaml 5.5 or later, and a Postgres to keep
the jobs in.

```sh
opam repo add open-opam https://github.com/open-opam/opam-repository.git
opam install spool rowtype-migrate
```

`spool` brings the libraries it runs over:
[rowtype](https://hyphatech.github.io/rowtype/) and its Postgres backend,
`rowtype-postgres`, and [wiretype](https://hyphatech.github.io/wiretype/),
which describes a job's payload. `rowtype-migrate` is the command that makes
spool's table, beside your own. The dashboard is a package of its own,
`spool-dashboard`, for an application served by
[Spindle](https://hyphatech.github.io/spindle/):

```sh
opam install spool-dashboard
```

A program names the libraries it uses in its `dune` file:

```lisp
(libraries spool rowtype-postgres eio_main)
```

The [quick start](quick-start.md) runs a whole program, next, and [In a
Spindle application](guide/spindle.md) puts spool in a web server.
