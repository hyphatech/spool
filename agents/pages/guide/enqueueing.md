# Enqueueing

`Spool.enqueue` writes a job through the caller's connection, in its
transaction, and answers its id.

## In your transaction

`enqueue` writes the row and nothing else, so a rollback leaves no job; a
runner hears of it when the transaction commits. The work that made the job
owed and the job itself are one transaction, written through one
connection:

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

A job written outside a transaction is committed at once, as any statement
is.

## When it runs

A job may run `~at` an instant, `~after` a span from now, and not after
`~expires_at`; given neither `~at` nor `~after`, it runs now. A job past
`expires_at` is discarded unrun. `~priority` overrides its kind's:

```ocaml title="enqueueing.ml"
(* Enqueueing: a job now, later, once for a key, and not after it stops
   being worth running.

     dune exec examples/enqueueing.exe *)

open Result.Syntax
module Pg = Rowtype_postgres

let database = "postgres://postgres:postgres@localhost:5432/postgres"

let order =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem "order" Wiretype.string ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt = Spool.Kind.make ~queue:"mail" "receipt.send" order
let reminder = Spool.Kind.make ~queue:"mail" "order.remind" order

let hours_on now hours =
  Option.value
    (Ptime.add_span now (Ptime.Span.of_int_s (hours * 3600)))
    ~default:Ptime.max

let schedule conn ~now order_id =
  (* in an hour, and never if it has not run within a day *)
  let* _ =
    Spool.enqueue conn ~now ~after:Mtime.Span.hour ~expires_at:(hours_on now 24)
      reminder order_id
  in
  (* at an instant, after every job of a higher priority due with it *)
  Spool.enqueue conn ~now ~at:(hours_on now 2) ~priority:9 reminder order_id

let explain = function
  | Ok id -> "job " ^ Spool.Id.to_string id
  | Error (`Bad_priority p) -> Printf.sprintf "priority %d is not 0 to 9" p
  | Error (`Unencodable e) -> Wiretype.Unwritable.to_string e
  | Error (#Pg.error as e) -> Pg.error_to_string e

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Pg.Conninfo.of_string database with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      match
        Pg.connect ~sw ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          conninfo
      with
      | Error e -> prerr_endline (Rowtype.error_to_string e)
      | Ok conn ->
          let now = Ptime_clock.now () in
          print_endline
            (explain
               (Spool.enqueue conn ~now ~unique:"A-1001" receipt "A-1001"));
          print_endline (explain (schedule conn ~now "A-1001"));
          Pg.close conn)
```

A runner claims the due jobs of a queue by priority, 0 first, then by the
instant each was due, then in the order they were written.

## Once for a key

A `~unique` key already waiting in the kind is that job, brought to the
earlier instant and the higher priority, and its id is the answer: asking
twice is one job. A key is unique among waiting jobs only, so a change made
while its job runs is a job of its own.

## What it answers

The job's `Spool.Id.t`, or why it was not written, as `explain` in
`enqueueing.ml` above tells them apart:

- `` `Bad_priority `` is a priority outside 0 to 9. A priority is a value a
  caller may compute, so one outside the range is refused rather than
  raised.
- `` `Unencodable `` is a payload its kind's description could not write.
- The rest is the statement's failure, as `rowtype` answers it, and inside
  `Rowtype_postgres.Transaction.within`, the transaction's own.

An id is a job's handle, for `find`, `cancel` and `retry`: a counter, so
never put where a stranger could read it.

## Once for a period

`~unique_for` holds a key for a period from the enqueue, whatever its job's
state: an enqueue of the kind and key within it is answered with that job,
waiting, running or already finished.

```ocaml
Spool.enqueue conn ~now ~unique:customer ~unique_for:Mtime.Span.hour digest d
```

The row is kept until the period ends -- pruning waits for it, and a kind
that keeps nothing keeps the row and not its payload. Without `~unique`, the
period holds for the kind: at most one job of it enqueued in any such
period.

## Many at once

`Spool.enqueue_many` writes many jobs of one kind in one statement, in the
caller's transaction:

```ocaml
Spool.enqueue_many conn ~now import_row rows
```

`~unique` gives each payload's key, and the first payload of a key stands for
the rest. It answers every job's id, each once and in no order -- what a job
that waits for all of them is given.
