(* An operator's hand: a job enqueued, found, cancelled and retried, and the
   queues' counts.

     dune exec examples/operating.exe *)

module Pg = Rowtype_postgres

let database = "postgres://postgres:postgres@localhost:5432/postgres"

let order =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem "order" Wiretype.string ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt = Spool.Kind.make ~queue:"mail" "receipt.send" order

let state_name : Spool.state -> string = function
  | Available -> "available"
  | Running -> "running"
  | Completed -> "completed"
  | Discarded -> "discarded"
  | Cancelled -> "cancelled"

let print_counts conn =
  match Spool.counts conn with
  | Error e -> prerr_endline (Rowtype.error_to_string e)
  | Ok counts ->
      List.iter
        (fun (queue, state, n) ->
          Printf.printf "%s %s %d\n" queue (state_name state) n)
        counts

let print_job conn id =
  match Spool.find conn id with
  | Error e -> prerr_endline (Rowtype.error_to_string e)
  | Ok None -> print_endline "no such job"
  | Ok (Some (job : Spool.info)) ->
      Printf.printf "%s in %s: %s, attempt %d of %d\n" job.kind job.queue
        (state_name job.state) job.attempt job.max_attempts;
      List.iter
        (fun (f : Spool.failed) ->
          Printf.printf "  attempt %d at %s: %s\n" f.attempt
            (Ptime.to_rfc3339 f.at) f.reason)
        job.errors

let cancel conn id =
  match Spool.cancel conn ~now:(Ptime_clock.now ()) id with
  | Ok true -> print_endline "cancelled"
  | Ok false -> print_endline "it had finished"
  | Error e -> prerr_endline (Rowtype.error_to_string e)

let retry conn id =
  match Spool.retry conn ~now:(Ptime_clock.now ()) id with
  | Ok (Some waiting) ->
      print_endline ("waiting as " ^ Spool.Id.to_string waiting)
  | Ok None -> print_endline "it was not discarded or cancelled"
  | Error e -> prerr_endline (Rowtype.error_to_string e)

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
          (match
             Spool.enqueue conn ~now:(Ptime_clock.now ()) receipt "A-1001"
           with
          | Ok id ->
              cancel conn id;
              retry conn id;
              print_job conn id;
              print_counts conn
          | Error (#Rowtype.error as e) ->
              prerr_endline (Rowtype.error_to_string e)
          | Error _ -> prerr_endline "the job could not be written");
          Pg.close conn)
