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
