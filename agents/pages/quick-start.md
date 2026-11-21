# Quick start

Work that outlives a request, kept where the rest of the application's
state is: a job is a row written in the transaction that made the work
owed, claimed by a runner under a lease, run outside every transaction,
retried with backoff, and finished once in the table however often it was
attempted. It runs over [rowtype](https://hyphatech.github.io/rowtype/)'s
Postgres backend and names no driver.

This page takes an order and owes it a receipt, in one transaction, then
runs a runner that sends the receipt. It needs spool and `rowtype-migrate`
[installed](index.md#install), and a Postgres.

## 1. A Postgres

Any Postgres you can reach will do. One in a container, thrown away when it
stops:

```sh
docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
```

## 2. The tables

spool keeps its jobs in a table of its own, made by its own migrations. The
order is yours, in a migration of your own, a SQL file in `migrations/`:

```console
$ rowtype-migrate new create_orders
migrations/20261024000000_create_orders.sql
```

```sql title="migrations/20261024000000_create_orders.sql"
-- create_orders: the quick start's own table, beside spool's.

create table orders (
  id     bigint generated always as identity primary key,
  email  text not null
);
```

Apply spool's migrations, then yours:

```sh
rowtype-migrate up --source spool --url postgres://postgres:postgres@localhost:5432/postgres
```

## 3. The receipt

A kind is a job's name, the [wiretype](https://hyphatech.github.io/wiretype/)
description of its payload, and how it is run -- here, in the queue `mail`.
The payload is an object, each member named for what it holds.

The order and its receipt are written in one transaction, through your own
connection, so a rollback leaves neither; a runner hears of the job when the
transaction commits. A runner claims the jobs of the queues it is given --
here `mail`, two at a time -- and runs each kind's handler. Its connections
are its own, made from the connection string.

Put this module in `bin/receipt.ml`:

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

## 4. The program

The program takes one order, starts the runner, gives it two seconds to send
the receipt, and stops it. Put it in `bin/main.ml`:

```ocaml title="quick_start.ml"
(* The quick start: one order taken, and a runner that sends its receipt;
   the order, its kind and the runner are receipt.ml.

     docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
     rowtype-migrate up --source spool --dir examples/migrations --url postgres://postgres:postgres@localhost:5432/postgres
     dune exec examples/quick_start.exe *)

open Result.Syntax
module Pg = Rowtype_postgres

let database = "postgres://postgres:postgres@localhost:5432/postgres"

let enqueue_error = function
  | #Pg.error as e -> Pg.error_to_string e
  | `Unencodable e -> Wiretype.Unwritable.to_string e
  | `Bad_priority p -> Printf.sprintf "priority %d is not 0 to 9" p

let main ~sw env =
  let* conninfo = Pg.Conninfo.of_string database in
  let* conn =
    Pg.connect ~sw ~net:(Eio.Stdenv.net env)
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      conninfo
    |> Result.map_error Rowtype.error_to_string
  in
  let* _job =
    Receipt.take_order conn ~now:(Ptime_clock.now ()) "ada@example.com"
    |> Result.map_error enqueue_error
  in
  let* runner =
    Receipt.runner ~sw env conninfo
    |> Result.map_error Spool.Runner.refused_to_string
  in
  Spool.Runner.start runner;
  Eio.Time.Mono.sleep_span (Eio.Stdenv.mono_clock env) Mtime.Span.(2 * s);
  Spool.Runner.stop runner;
  Pg.close conn;
  Ok ()

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match main ~sw env with
  | Ok () -> ()
  | Error e ->
      prerr_endline e;
      exit 1
```

Name the libraries it uses in `bin/dune`, with a `dune-project` holding
`(lang dune 3.18)` beside `bin/`:

```lisp
(executable
 (name main)
 (libraries spool rowtype rowtype-postgres wiretype eio eio_main ptime.clock.os mtime))
```

```console
$ dune exec ./bin/main.exe
Receipt for order 1 sent.
```

Each run takes another order and sends its receipt.

## Next

- [The table](guide/table.md): the migrations, and what each column
  holds.
- [Kinds](guide/kinds.md) and [Enqueueing](guide/enqueueing.md):
  when a job runs, and how often.
- [Handlers](guide/handlers.md) and [The
  runner](guide/runner.md): what an attempt answers, and what the
  runner does with it.
- [In a Spindle application](guide/spindle.md): a route that owes a
  job in its request's transaction, and a runner beside the server.
