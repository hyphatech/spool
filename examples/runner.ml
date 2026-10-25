(* A runner beside the application: made where the program starts,
   started, and stopped as the program ends. The receipt's handler is
   mail.ml.

     dune exec examples/runner.exe *)

module Pg = Rowtype_postgres

let database = "postgres://postgres:postgres@localhost:5432/postgres"

let order =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem "order" Wiretype.string ~enc:Fun.id
  |> Wiretype.Object.finish

let report = Spool.Kind.make ~queue:"reports" "report.monthly" order
let build_report _order = Ok ()

(* Stands for the application's own work, a server say, until it ends. *)
let serve env =
  Eio.Time.Mono.sleep_span (Eio.Stdenv.mono_clock env) Mtime.Span.min

let run ~sw env conninfo =
  match
    Spool.Runner.create ~sw ~net:(Eio.Stdenv.net env)
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~now:Ptime_clock.now ~pool_size:3
      ~lease:Mtime.Span.(2 * min)
      ~retain_completed:Mtime.Span.hour
      ~queues:[ ("mail", 4); ("reports", 1) ]
      [
        Spool.handle Mail.receipt Mail.send_receipt;
        Spool.handle report (fun _job order -> build_report order);
      ]
      conninfo
  with
  | Error refused -> prerr_endline (Spool.Runner.refused_to_string refused)
  | Ok runner ->
      Spool.Runner.start runner;
      serve env;
      Spool.Runner.stop ~grace:Mtime.Span.(30 * s) runner

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Pg.Conninfo.of_string database with
  | Error e -> prerr_endline e
  | Ok conninfo -> run ~sw env conninfo
