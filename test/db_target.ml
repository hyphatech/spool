(* Where a test's database comes from.

   The suite needs a Postgres server, named by SPOOL_TEST_PG, which
   `make test` sets after bringing the tests' own container up. A bare
   `dune test` leaves it unset, and the suite skips itself and SAYS so,
   rather than failing on a machine with no Docker or passing without having
   run. *)

let base = Sys.getenv_opt "SPOOL_TEST_PG"

let required ~suite =
  if Option.is_none base then begin
    Printf.printf
      "  [%s skipped: no SPOOL_TEST_PG -- set it to a Postgres server's URL]\n\
       %!"
      suite;
    exit 0
  end

let loop : (Eio_unix.Stdenv.base * Eio.Switch.t) option ref = ref None
let eio env ~sw = loop := Some ((env :> Eio_unix.Stdenv.base), sw)

let io () =
  match !loop with
  | Some v -> v
  | None -> Alcotest.fail "the suite did not call Db_target.eio env ~sw"

let sw () = snd (io ())
let net () = Eio.Stdenv.net (fst (io ()))
let mono () = Eio.Stdenv.mono_clock (fst (io ()))

let server () =
  match base with
  | None -> Alcotest.fail "SPOOL_TEST_PG is not set"
  | Some server -> server

let conninfo url =
  match Rowtype_postgres.Conninfo.of_string url with
  | Ok c -> c
  | Error e -> Alcotest.failf "a URL: %s" e

let on_database name =
  Rowtype_postgres.Conninfo.with_database (conninfo (server ())) name

let connect conninfo =
  match
    Rowtype_postgres.connect ~sw:(sw ()) ~net:(net ()) ~mono_clock:(mono ())
      conninfo
  with
  | Ok db -> db
  | Error e -> Alcotest.failf "cannot connect: %s" (Rowtype.error_to_string e)

let exec db sql =
  match Rowtype_postgres.exec_raw db sql with
  | Ok () -> ()
  | Error e -> Alcotest.failf "%s: %s" sql (Rowtype.error_to_string e)

let admin f =
  let db = connect (conninfo (server ())) in
  Fun.protect ~finally:(fun () -> Rowtype_postgres.close db) (fun () -> f db)

(* A database of its own per case, so one case cannot see another's rows;
   dropped [with (force)], since a runner a case failed to stop would
   otherwise hold it. *)
let nth = ref 0

let with_postgres f =
  incr nth;
  let name = Printf.sprintf "spool_test_%d_%d" (Unix.getpid ()) !nth in
  admin (fun db -> exec db (Printf.sprintf "create database %s" name));
  let finally () =
    admin (fun db ->
        exec db (Printf.sprintf "drop database if exists %s with (force)" name))
  in
  Fun.protect ~finally (fun () -> f (on_database name))
