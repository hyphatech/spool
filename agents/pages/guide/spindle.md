# In a Spindle application

spool is a library: in an application served by
[Spindle](https://hyphatech.github.io/spindle/), a route owes a job in the
transaction its request writes in, and a runner beside the server does the
work. There is no spool process to start, and nothing of Spindle's to
change.

```ocaml title="spindle.ml"
(* spool in a Spindle application: a route takes an order and owes its
   receipt in the request's transaction, and a runner beside the server sends
   it. The orders table is examples/migrations'.

     rowtype-migrate up --source spool --dir examples/migrations
     dune exec examples/spindle.exe
     curl localhost:8080/orders -H 'content-type: application/json' \
       -d '{"email": "ada@example.com"}' *)

open Spindle.Syntax
module Pg = Rowtype_postgres

let database =
  Option.value
    (Sys.getenv_opt "DATABASE_URL")
    ~default:"postgres://postgres:postgres@localhost:5432/postgres"

(* {"order": 42} *)
let order =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem "order" Wiretype.int ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt = Spool.Kind.make ~queue:"mail" "receipt.send" order

let send_receipt (_ : Spool.job) order =
  Printf.printf "Receipt for order %d sent.\n%!" order;
  Ok ()

(* {"email": "ada@example.com"} *)
let email =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem "email" Wiretype.string ~enc:Fun.id
  |> Wiretype.Object.finish

let insert_order =
  Rowtype.find ~params:Rowtype.text ~row:Rowtype.int
    "insert into orders (email) values ($1) returning id"

(* The application's pool, the one its routes already read. *)
let db : Spindle_postgres.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

(* A payload the kind cannot write, or a priority out of range, is a bug of
   the program's, never the caller's. *)
let refusal = function
  | `Unencodable _ | `Bad_priority _ ->
      Spindle.Refusal.internal ~detail:"the receipt could not be enqueued"
  | #Spindle_postgres.error as e -> Spindle_postgres.refusal e

(* The order and its receipt in one transaction: a rollback leaves neither,
   and the runner hears of the job when it commits. *)
let take_order =
  Spindle.post ~summary:"Take an order, and owe its receipt"
    Spindle.Path.(s "orders")
    (Spindle.Returns.json order)
    (let+ pool = db and+ now = Spindle.now and+ email = Spindle.json email in
     Spindle_postgres.Pool.transaction pool (fun conn ->
         let* id = Pg.run conn insert_order email in
         let* _job =
           Spool.enqueue conn ~now ~unique:(string_of_int id) receipt id
         in
         Ok id)
     |> Result.map_error refusal)

(* The runner starts before the server listens and stops once it has
   stopped, so a job owed by the last request is still sent, or left for the
   next deploy's runner. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and mono_clock = Eio.Stdenv.mono_clock env in
  match Pg.Conninfo.of_string database with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      match Spindle_postgres.Pool.create ~sw ~net ~mono_clock conninfo with
      | Error e -> prerr_endline (Rowtype.error_to_string e)
      | Ok pool -> (
          match
            Spool.Runner.create ~sw ~net ~mono_clock ~now:Ptime_clock.now
              ~queues:[ ("mail", 4) ]
              [ Spool.handle receipt send_receipt ]
              conninfo
          with
          | Error refused ->
              prerr_endline (Spool.Runner.refused_to_string refused)
          | Ok runner ->
              Spool.Runner.start runner;
              Spindle.serve env
                ~resources:[ Spindle.Dep.resource db pool ]
                [ take_order ];
              Spool.Runner.stop runner;
              Spindle_postgres.Pool.close pool))
```

## A job in the request's transaction

A route reads the pool the application already holds as a resource, and
`Spindle_postgres.Pool.transaction` runs its writes in one transaction:
`Ok` commits, `Error` rolls back. `Spool.enqueue` takes the same
connection, so the order and its receipt are written together, a refusal
leaves neither, and the runner hears of the job when the transaction
commits. A unique key, here the order's id, makes a request sent twice one
job.

What enqueueing can answer beside a statement's failure -- a payload its
kind cannot write, a priority out of range -- is the program's bug, never
the caller's, so it is an internal refusal, a `500`;
`Spindle_postgres.refusal` words the rest, a pool busy as a `503`.

## The runner beside the server

A runner has its own connections, made from the same connection string --
a small pool and a listener -- because one borrowed from the application's
would lose its heartbeats when the application is busiest ([The
runner](runner.md#its-own-connections)). It is started before
the server listens, and stopped once `Spindle.serve` returns, which it does
when the process is told to stop: running jobs get their grace, and what
is left is put back for the next deploy's runner.

A runner may instead run in a program of its own, with no server at all;
the application then only enqueues, which needs none ([Where it
runs](runner.md#where-it-runs)).

## The dashboard

`spool-dashboard` is routes the same server serves, beside the
application's own, behind its own sign-in: [The
dashboard](dashboard.md).

```ocaml
Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ]
  ([ take_order ]
  @ Spool_dashboard.routes ~operator ~may ~pool:db ~mono_clock ())
```

## Kinds are one per name

A kind's name is its identity in the table, and every runner on a database
claims every job of a kind it handles. Two programs on one database that
make a kind of one name with two payload shapes discard each other's jobs
as unreadable: one name, one kind, wherever it is made.
