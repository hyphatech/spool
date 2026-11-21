# Testing

`Runner.drain` runs every job due at `now ()` through the runner's own claim
and finish, one at a time on the caller's fiber, and answers what each
attempt left the job: a test moves its clock and drains, and nothing
sleeps.

```ocaml title="testing.ml"
(* A test of a handler through the runner's own claim and finish, with a
   clock the test moves, so nothing sleeps for a backoff. It needs a
   database of its own, made by spool's migrations, since a drain runs every
   job due in it.

     dune exec examples/testing.exe *)

module Pg = Rowtype_postgres

let database = "postgres://postgres:postgres@localhost:5432/postgres"

let order =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem "order" Wiretype.string ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt = Spool.Kind.make ~queue:"mail" "receipt.send" order

let state_name : Spool.state -> string = function
  | Available -> "available"
  | Blocked -> "blocked"
  | Running -> "running"
  | Completed -> "completed"
  | Discarded -> "discarded"
  | Cancelled -> "cancelled"

let ok what = function Ok v -> v | Error e -> Alcotest.failf "%s: %s" what e

let test_a_busy_service_is_tried_again () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let at = ref (Ptime_clock.now ()) in
  let now () = !at in
  let busy = ref true in
  let send_receipt _job _order =
    if !busy then (
      busy := false;
      Error (Spool.Retry "the mail service is busy"))
    else Ok ()
  in
  let conninfo = ok "conninfo" (Pg.Conninfo.of_string database) in
  let runner =
    Spool.Runner.create ~sw ~net:(Eio.Stdenv.net env)
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~now
      ~queues:[ ("mail", 1) ]
      [ Spool.handle receipt send_receipt ]
      conninfo
    |> Result.map_error Spool.Runner.refused_to_string
    |> ok "runner"
  in
  let conn =
    Pg.connect ~sw ~net:(Eio.Stdenv.net env)
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      conninfo
    |> Result.map_error Rowtype.error_to_string
    |> ok "connect"
  in
  let (_ : Spool.Id.t) =
    Spool.enqueue conn ~now:(now ()) receipt "A-1001"
    |> Result.map_error (fun _ -> "the job could not be written")
    |> ok "enqueue"
  in
  let drain () =
    Spool.Runner.drain runner |> ok "drain"
    |> List.map (fun (_, state) -> state_name state)
  in
  Alcotest.(check (list string)) "retried" [ "available" ] (drain ());
  Alcotest.(check (list string)) "not before its backoff" [] (drain ());
  at := Option.value (Ptime.add_span !at (Ptime.Span.of_int_s 60)) ~default:!at;
  Alcotest.(check (list string)) "then sent" [ "completed" ] (drain ());
  Spool.Runner.stop runner;
  Pg.close conn

let () =
  Alcotest.run "receipts"
    [
      ( "receipt.send",
        [
          Alcotest.test_case "a busy service is tried again" `Quick
            test_a_busy_service_is_tried_again;
        ] );
    ]
```

- The runner is made as a program makes one, with a `now` the test moves,
  and never started: `drain` runs the jobs, and no fiber of the runner's
  does.
- Each drain answers a job's id and its state once the attempt was
  finished: `Available` for one to be retried, `Completed`, `Discarded`.
  A job expired before it ran is answered `Discarded` too.
- A drain claims nothing that is not due: a retried job waits its backoff,
  15 s for the first, spread by a tenth either way, until the test moves
  its clock past it.
- A drain runs every job due in the database, so each test has a database
  of its own, made by spool's migrations.
