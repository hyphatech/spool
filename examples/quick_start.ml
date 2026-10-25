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
