(* A test that every statement the application runs is what its database
   says, spool's among them, so a migration that renamed a column fails a
   test and not a job.

     dune exec examples/verify.exe *)

module Pg = Rowtype_postgres

let database = "postgres://postgres:postgres@localhost:5432/postgres"

let orders =
  Rowtype.list ~params:Rowtype.unit
    ~row:Rowtype.(t2 int text)
    "select id, email from orders order by id"

let check conn =
  match Pg.verify conn (Spool.statements @ [ Rowtype.Any orders ]) with
  | Ok () -> print_endline "Every statement agrees with the database."
  | Error (`Disagreements problems) -> List.iter prerr_endline problems
  | Error (#Rowtype.error as e) -> prerr_endline (Rowtype.error_to_string e)

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
          check conn;
          Pg.close conn)
