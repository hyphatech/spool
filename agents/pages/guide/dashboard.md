# The dashboard

`spool-dashboard` watches and steers the queue from the application that
runs it: routes added to its own Spindle server, open to whom it says and
for what.

```sh
opam install spool-dashboard
```

```ocaml
let db : Spindle_postgres.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

let operator = Spindle.Access.principal ~id:Auth.user_id Auth.signed_in

let may (user : Auth.user) (action : Spool_dashboard.action) :
    Spindle.Access.decision =
  match (user.role, action) with
  | (Support | Admin), View | Admin, _ -> Allow
  | Support, _ -> Deny "support only looks"
  | Customer, _ -> Deny "not an operator"

let routes =
  Routes.routes
  @ Spool_dashboard.routes ~operator ~may ~pool:db ~mono_clock ()
```

The page at `/spool` shows, live, a column of the queue's state beside its
work. The column:

- **States**: what waits, is blocked and runs, exactly; what completed and
  was discarded in the last 24 hours, summed from spool's statistics; and
  cancelled, which nothing counts without reading every finished row. A
  state chosen there filters the job list.
- **Queues**, each with a switch that pauses and resumes it, the limits it
  holds, and a form that sets them: how many of its jobs run at once and how
  many attempts begin in a period, across every runner, and whether each
  holds for every partition of it.
- **Schedules**, each with its expression and zone, its next tick, and a
  button that runs it now.
- **Workers**, each runner running: its host, its queues and their slots,
  and when it was last seen.

Beside it, **a chart** of the attempts finished each minute over the last
hour, completed, retried and discarded; and **the jobs**,
newest first, by state, queue and kind, a page at a time, a selection of
them retried, cancelled or deleted at once. A job opened shows its attempts
and why each failed, oldest first, its payload, and, where it is in a
workflow, the jobs it waits for and those waiting on it, each with its state
and opened from there.

Live updates can be paused from the page. It wears Hypha's look, light or
dark as the system is or as chosen.

## Who may do what

The application says, and there is no default, since the dashboard cancels
and deletes and an open default is how it ends up public. It gives two
things, through Spindle's `Access`:

- **`operator`**: who calls, as the application knows them -- its own user,
  read from its session or a bearer token. Nobody signed in is a `401`.
- **`may`**: what they may do, a function of that user and a
  `Spool_dashboard.action` -- `View`, `Cancel`, `Retry`, `Delete`,
  `Run_again`, `Pause`, `Resume`, `Set_limits` and `Run_schedule` --
  answering `Allow` or `Deny` with a reason. It reads what the application
  keeps, a role, a flag or a scope, so a user given or refused access is a
  change to their row, not to the code.

Every route asks before it reads or does anything, and answers a denial
with a `403` and nothing more; Spindle writes each denial on its
`spindle.access` source, naming the caller and the reason, and
`Spindle.Access.unguarded` lists none of the dashboard's routes. The page
shows only what its viewer may do: a viewer allowed `View` alone sees the
queue and changes nothing.

The live stream is one request, asked once, so it ends after `?stream_for`,
a minute unless given, and the page opens the next at once, which asks
again: someone whose access the application took away sees the queue no
longer than that.

## What it does

Whatever the dashboard does, it does through spool's own functions:
`Spool.jobs`, `Spool.find` and `Spool.workflow` to read, `Spool.cancel`,
`Spool.retry` and `Spool.delete` for a job or a selection, `Spool.Queue.pause`,
`resume` and `set_limits`, and `Schedule.run_now`. It can do nothing code
cannot, under the same checks. Each action is a line on the
`spool-dashboard` source, at `Info`, saying what it was done to; the line
carries its request's id, and the request's trace who made it. A kind made `~sensitive` shows "Hidden: its kind is sensitive"
where its payload would be, since spool answers none.

The live state is one stream of Server-Sent Events, `GET /spool/api/live`.
Once a second, while anyone watches, one fiber of the process reads the
counts, the queues, the runners, the schedules and the latest statistics,
and every viewer is sent each part that changed. `mono_clock` times it.

## Installed with OCaml alone

The page is built into the package: its files are compiled into the library
and served from memory, the hashed ones kept a year by the browser and the
page asked for again each time. Nothing is built, fetched or reached where
it runs. It calls its routes relative to where it is served, so it works
under `~at` anywhere, and behind any prefix a proxy puts it.

## An example

Two runners, a schedule every minute, a queue limited to one job at a time
per customer, an import whose summary waits for its rows, a kind whose
payload is a secret, and a stream of work that sometimes fails. Spool's
tables are made first, by `rowtype-migrate up --source spool`; then
`dune exec examples/dashboard.exe` prints the dashboard's address.

```ocaml title="dashboard.ml"
(* The dashboard in an application: Spindle serving it at /spool beside two
   runners, a schedule every minute, a queue limited per customer, an import
   whose summary waits for its rows, a kind whose payload is a secret, and a
   stream of work that sometimes fails, so there is something to watch.
   Spool's tables are made first, by rowtype-migrate up --source spool.

     dune exec examples/dashboard.exe *)

open Spindle.Syntax
module Pg = Rowtype_postgres

let database =
  Option.value
    (Sys.getenv_opt "DATABASE_URL")
    ~default:"postgres://postgres:postgres@localhost:5432/postgres"

let port = 4400

let one name ty =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem name ty ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt =
  Spool.Kind.make ~queue:"mail" "receipt.send" (one "order" Wiretype.string)

(* One customer's syncs at a time, the customers taken in turns. *)
let sync =
  Spool.Kind.make ~queue:"partner" ~max_attempts:5 ~partition:Fun.id
    "partner.sync"
    (one "customer" Wiretype.string)

let charge =
  Spool.Kind.make ~queue:"payments" ~sensitive:true "card.charge"
    (one "card" Wiretype.string)

let row =
  Spool.Kind.make ~queue:"imports" "import.row" (one "line" Wiretype.int)

let summary =
  Spool.Kind.make ~queue:"imports" "import.summary" (one "file" Wiretype.string)

let report =
  Spool.Kind.make ~queue:"reports" "report.minute" (one "day" Wiretype.string)

let every_minute =
  Spool.Schedule.make ~name:"report.every-minute" ~cron:"* * * * *" ~zone:"UTC"
    report "today"

(* Who calls and what they may do: here, a caller is their address, and
   whoever is on this machine may do anything. An application's caller is its
   own user, from its sessions or tokens, and [may] reads their role. *)
let operator = Spindle.Access.principal ~id:Fun.id Spindle.client_ip

let may ip (_ : Spool_dashboard.action) : Spindle.Access.decision =
  match ip with "127.0.0.1" | "::1" -> Allow | _ -> Deny "not on this machine"

let db : Spindle_postgres.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

(* Work that takes a moment and fails now and then, some of it for good. *)
let work ~clock ~random ~up_to_ms ~fails _job _payload =
  let took = Random.State.int random up_to_ms in
  Eio.Time.Mono.sleep_span clock Mtime.Span.(took * ms);
  let draw = Random.State.int random 100 in
  if draw < fails then Error (Spool.Retry "the partner did not answer")
  else if draw < fails + 2 then
    Error (Spool.Discard "the order no longer exists")
  else Ok ()

(* Each queue's kinds and how they go, for a runner of the queue. *)
let handlers ~clock ~random queue =
  let work ~up_to_ms ~fails = work ~clock ~random ~up_to_ms ~fails in
  match queue with
  | "mail" -> [ Spool.handle receipt (work ~up_to_ms:400 ~fails:10) ]
  | "partner" -> [ Spool.handle sync (work ~up_to_ms:1500 ~fails:20) ]
  | "payments" -> [ Spool.handle charge (work ~up_to_ms:300 ~fails:5) ]
  | "imports" ->
      [
        Spool.handle row (work ~up_to_ms:200 ~fails:3);
        Spool.handle summary (work ~up_to_ms:500 ~fails:0);
      ]
  | "reports" -> [ Spool.handle report (work ~up_to_ms:800 ~fails:0) ]
  | _ -> []

let runner ~sw env ~random ~queues conninfo =
  let clock = Eio.Stdenv.mono_clock env in
  match
    Spool.Runner.create ~sw ~net:(Eio.Stdenv.net env) ~mono_clock:clock
      ~now:Ptime_clock.now ~schedules:[ every_minute ] ~queues
      (List.concat_map (fun (queue, _) -> handlers ~clock ~random queue) queues)
      conninfo
  with
  | Ok r ->
      Spool.Runner.start r;
      Ok r
  | Error refused -> Error (Spool.Runner.refused_to_string refused)

let enqueued = function
  | Ok _ -> ()
  | Error (#Rowtype.error as e) -> prerr_endline (Rowtype.error_to_string e)
  | Error (`Unencodable e) -> prerr_endline (Wiretype.Unwritable.to_string e)
  | Error (`Bad_priority p) -> prerr_endline ("priority " ^ string_of_int p)

(* An import: a job a row, and a summary once every row completed. *)
let import conn ~file =
  let now = Ptime_clock.now () in
  enqueued
    (let* rows = Spool.enqueue_many conn ~now row (List.init 8 Fun.id) in
     Spool.enqueue_after conn ~now ~waits_for:rows summary file)

(* Something to watch: a few jobs every second, of every kind. *)
let rec generate env pool ~random n : [ `Stop_daemon ] =
  let customers = [| "acme"; "globex"; "initech"; "umbrella" |] in
  let now = Ptime_clock.now () in
  (match
     Spindle_postgres.Pool.use pool (fun conn ->
         enqueued (Spool.enqueue conn ~now receipt ("A-" ^ string_of_int n));
         enqueued
           (Spool.enqueue conn ~now sync
              customers.(Random.State.int random (Array.length customers)));
         if n mod 3 = 0 then
           enqueued (Spool.enqueue conn ~now charge "4242 4242 4242 4242");
         if n mod 20 = 0 then
           import conn ~file:("orders-" ^ string_of_int n ^ ".csv");
         Ok ())
   with
  | Ok () -> ()
  | Error e -> prerr_endline (Spindle_postgres.error_to_string e));
  Eio.Time.Mono.sleep_span (Eio.Stdenv.mono_clock env) Mtime.Span.(700 * ms);
  generate env pool ~random (n + 1)

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let random = Random.State.make_self_init () in
  match Pg.Conninfo.of_string database with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      let net = Eio.Stdenv.net env and mono_clock = Eio.Stdenv.mono_clock env in
      match Spindle_postgres.Pool.create ~sw ~net ~mono_clock conninfo with
      | Error e -> prerr_endline (Rowtype.error_to_string e)
      | Ok pool -> (
          let limited =
            Spindle_postgres.Pool.use pool (fun conn ->
                Spool.Queue.set_limits conn ~now:(Ptime_clock.now ())
                  ~running:(Some 1) ~rate:None ~per_partition:true "partner")
          in
          (match limited with
          | Ok () -> ()
          | Error (`Bad_limit why) -> prerr_endline why
          | Error (#Spindle_postgres.error as e) ->
              prerr_endline (Spindle_postgres.error_to_string e));
          let first =
            runner ~sw env ~random
              ~queues:[ ("mail", 4); ("partner", 4); ("imports", 2) ]
              conninfo
          and second =
            runner ~sw env ~random
              ~queues:
                [ ("mail", 2); ("payments", 2); ("imports", 2); ("reports", 1) ]
              conninfo
          in
          match (first, second) with
          | Error e, _ | _, Error e -> prerr_endline e
          | Ok first, Ok second ->
              Eio.Fiber.fork_daemon ~sw (fun () -> generate env pool ~random 0);
              Spindle.serve env ~port
                ~resources:[ Spindle.Dep.resource db pool ]
                ~ready:(fun _ ->
                  print_endline
                    ("The dashboard: http://localhost:" ^ string_of_int port
                   ^ "/spool"))
                (Spool_dashboard.routes ~operator ~may ~pool:db ~mono_clock ());
              Spool.Runner.stop first;
              Spool.Runner.stop second))
```
