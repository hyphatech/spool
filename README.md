# spool

[![ci](https://img.shields.io/github/actions/workflow/status/hyphatech/spool/ci.yml?branch=main&label=ci)](https://github.com/hyphatech/spool/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/hyphatech/spool?label=release)](https://github.com/hyphatech/spool/releases)
[![license](https://img.shields.io/github/license/hyphatech/spool)](LICENSE)
![OCaml 5.5+](https://img.shields.io/badge/OCaml-5.5%2B-EC6813?logo=ocaml&logoColor=white)
[![Hypha Stack](https://img.shields.io/badge/Hypha-Stack-d4a820?labelColor=15120e)](https://hyphatech.io/stack/)

Durable jobs for modern OCaml, backed by Postgres.
Transactional, reliable and testable. Eio-native and multicore-ready.

**Documentation**: [hyphatech.github.io/spool](https://hyphatech.github.io/spool/)

## Features

- **In your transaction**: a job is a row written with the work that made it owed, so a rollback leaves no job.
- **Several processes, one queue**: claims that never wait on each other, leases a heartbeat renews, and a lapsed one rescued.
- **Retries with backoff**: a handler retries, retries after what an upstream said, or discards.
- **Asked twice, one job**: a unique key folds a second request into the job already waiting.
- **Scheduled and prioritised**: at an instant, after a span, until an expiry, at a priority from 0 to 9.
- **Tests that never sleep**: `Runner.drain` runs every job due at the test's own clock.

## Install

```sh
opam repo add hypha https://github.com/hyphatech/opam-repository.git
opam install spool rowtype-migrate
```

```lisp
(libraries spool rowtype-postgres eio_main)
```

spool's table is made by its own migrations, applied beside yours before
your application starts:

```sh
rowtype-migrate up --source spool    # spool's migrations, then yours
```

A whole program: [the quick start](https://hyphatech.github.io/spool/quick-start/).

## Example

```ocaml
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

The runner claims the job once the transaction commits, under a lease, and
runs its handler outside every transaction; `Spool.Runner.start` starts it
and `Spool.Runner.stop` stops it.

## Contributing

See [AGENTS.md](AGENTS.md).

## Licence

MIT, copyright Hypha Technologies Ltd. See [LICENSE](LICENSE).
