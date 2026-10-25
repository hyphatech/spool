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
