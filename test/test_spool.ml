(* The queue against a real Postgres: a case's own database, the table made
   from the package's own schema, and runners on the suite's switch.

   Cases about what one attempt comes to run through [drain] with a clock the
   case moves, so nothing sleeps for a backoff; cases about leases,
   notifications and stopping start real runners with short leases and
   polls, and wait for what they say on a real clock. *)

module J = Spool
module Pg = Rowtype_postgres

(* The table as spool's own migrations make it: the files it installs, run
   in order, so the suite runs against what a user's migrate step makes. *)
let migrations =
  let dir = "../migrations" in
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".sql")
  |> List.sort String.compare
  |> List.map (fun f ->
      In_channel.with_open_bin (Filename.concat dir f) In_channel.input_all)

let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

(* The wall clock's time, as a program reads its [now]. *)
let real_now () = Ptime_clock.now ()

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i =
    i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1))
  in
  go 0

(* [t] moved on by [span], as a case moves its clock. *)
let plus t span =
  let ns = Mtime.Span.to_uint64_ns span in
  match
    Ptime.add_span t
      (Ptime.Span.v
         ( Int64.to_int (Int64.div ns 86_400_000_000_000L),
           Int64.mul (Int64.rem ns 86_400_000_000_000L) 1000L ))
  with
  | Some t -> t
  | None -> Alcotest.fail "a moved clock left the years 0000 to 9999"

let instant = Alcotest.testable (Ptime.pp_rfc3339 ~frac_s:6 ()) Ptime.equal

let state =
  Alcotest.testable
    (fun f s ->
      Format.pp_print_string f
        (match s with
        | J.Available -> "available"
        | Blocked -> "blocked"
        | Running -> "running"
        | Completed -> "completed"
        | Discarded -> "discarded"
        | Cancelled -> "cancelled"))
    ( = )

let ok what = function
  | Ok v -> v
  | Error e -> Alcotest.failf "%s: %s" what (Rowtype.error_to_string e)

(* A case's database with the table in it, a connection to it, and its URL
   for runners. *)
let with_table f =
  Db_target.with_postgres (fun target ->
      let conn = Db_target.connect target in
      Fun.protect
        ~finally:(fun () -> Pg.close conn)
        (fun () ->
          List.iter (Db_target.exec conn) migrations;
          f target conn))

(* A clock a case moves, starting at the real instant so a runner on a real
   clock agrees with it, to the millisecond, so an instant written to the
   database reads back as it was. *)
let clock () =
  let at = ref (Ptime.truncate ~frac_s:3 (real_now ())) in
  ((fun () -> !at), at)

let enqueue ?at ?after ?priority ?unique ?unique_for ?expires_at conn ~now kind
    arg =
  match
    Pg.Transaction.within conn (fun c ->
        J.enqueue ?at ?after ?priority ?unique ?unique_for ?expires_at c ~now
          kind arg)
  with
  | Ok id -> id
  | Error (#Rowtype.error as e) ->
      Alcotest.failf "enqueue: %s" (Rowtype.error_to_string e)
  | Error (`Unencodable e) ->
      Alcotest.failf "enqueue: unencodable: %s"
        (Wiretype.Unwritable.to_string e)
  | Error (`Bad_priority p) -> Alcotest.failf "enqueue: priority %d" p
  | Error (`Not_committed m) -> Alcotest.failf "enqueue: not committed: %s" m

let find conn id =
  match ok "find" (J.find conn id) with
  | Some info -> info
  | None -> Alcotest.fail "no such job"

let runner ?(queues = [ ("default", 4) ]) ?poll ?lease ?retain_completed
    ?schedules ~now target handlers =
  match
    J.Runner.create ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
      ~mono_clock:(Db_target.mono ()) ~now ?poll ?lease ?retain_completed
      ?schedules ~queues handlers target
  with
  | Ok r -> r
  | Error e -> Alcotest.failf "create: %s" (J.Runner.refused_to_string e)

let drain r =
  match J.Runner.drain r with
  | Ok outcomes -> outcomes
  | Error m -> Alcotest.failf "drain: %s" m

let outcomes =
  Alcotest.(
    list
      (pair
         (testable
            (fun f id -> Format.pp_print_string f (J.Id.to_string id))
            J.Id.equal)
         state))

let sleep span = Eio.Time.Mono.sleep_span (Db_target.mono ()) span
let mono_now () = Eio.Time.Mono.now (Db_target.mono ())

(* Wait on a real clock for what a started runner should do. *)
let eventually ?(within = Mtime.Span.(5 * s)) what cond =
  let started = mono_now () in
  let rec go () =
    if cond () then ()
    else if Mtime.Span.is_longer (Mtime.span started (mono_now ())) ~than:within
    then Alcotest.failf "never: %s" what
    else (
      sleep Mtime.Span.(50 * ms);
      go ())
  in
  go ()

(* A payload of one member, named for what it holds. *)
let one mem ty =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem mem ty ~enc:Fun.id
  |> Wiretype.Object.finish

let text ?queue ?max_attempts ?timeout ?keep name =
  J.Kind.make ?queue ?max_attempts ?timeout ?keep name
    (one "note" Wiretype.string)

let done_ _ _ = Ok ()

(* ------------------------------------------------------------------ *)
(* Enqueueing *)

let test_a_rolled_back_enqueue_leaves_nothing () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "note" in
      (match
         Pg.Transaction.within conn (fun c ->
             match J.enqueue c ~now:(now ()) kind "hello" with
             | Ok _ -> Error (`Db "the caller's own failure")
             | Error e -> Error e)
       with
      | Ok _ -> Alcotest.fail "the transaction committed"
      | Error _ -> ());
      Alcotest.(check (list (triple string state int)))
        "no job" []
        (ok "counts" (J.counts conn));
      let r = runner ~now target [ J.handle kind done_ ] in
      Alcotest.check outcomes "and nothing runs" [] (drain r);
      J.Runner.stop r)

let test_a_key_is_folded_into_the_waiting_job () =
  with_table (fun _ conn ->
      let now, _ = clock () in
      let kind = text "note" in
      let a =
        enqueue conn ~now:(now ())
          ~after:Mtime.Span.(5 * s)
          ~priority:5 ~unique:"k" kind "a"
      in
      let b =
        enqueue conn ~now:(now ()) ~after:Mtime.Span.s ~priority:2 ~unique:"k"
          kind "b"
      in
      check_bool "one job" true (J.Id.equal a b);
      let info = find conn a in
      Alcotest.check instant "at the earlier instant"
        (plus (now ()) Mtime.Span.s)
        info.scheduled_at;
      check_int "and the higher priority" 2 info.priority;
      let c = enqueue conn ~now:(now ()) ~unique:"other" kind "c" in
      check_bool "another key is another job" false (J.Id.equal a c))

let test_a_bad_priority_is_refused () =
  with_table (fun _ conn ->
      let now, _ = clock () in
      check_bool "refused as a value" true
        (match J.enqueue conn ~now:(now ()) ~priority:12 (text "note") "x" with
        | Error (`Bad_priority 12) -> true
        | Ok _ | Error _ -> false);
      check_bool "and a kind's own, raised" true
        (match J.Kind.make ~priority:10 "loud" (one "note" Wiretype.string) with
        | _ -> false
        | exception Invalid_argument _ -> true))

let test_a_payload_is_an_object () =
  let refused payload =
    match J.Kind.make "bare" payload with
    | _ -> false
    | exception Invalid_argument _ -> true
  in
  let key payload =
    Wiretype.kind ~kind:"key" ~parse:Result.ok ~print:Fun.id payload
  in
  check_bool "a bare string is refused" true (refused Wiretype.string);
  check_bool "and a kind over one" true (refused (key Wiretype.string));
  check_bool "an object is not" false (refused (one "note" Wiretype.string));
  check_bool "nor a kind over one" false
    (refused (key (one "note" Wiretype.string)))

let test_every_statement_is_what_the_database_says () =
  with_table (fun _ conn ->
      match Pg.verify conn J.statements with
      | Ok () -> ()
      | Error (`Disagreements problems) ->
          Alcotest.failf "%s" (String.concat "\n" problems)
      | Error (#Rowtype.error as e) -> Alcotest.fail (Rowtype.error_to_string e))

(* ------------------------------------------------------------------ *)
(* One attempt, through drain *)

let test_done_is_completed () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "note" in
      let seen = ref [] in
      let id = enqueue conn ~now:(now ()) kind "hello" in
      let r =
        runner ~now target
          [
            J.handle kind (fun (job : J.job) arg ->
                seen := (job.attempt, arg) :: !seen;
                Ok ());
          ]
      in
      Alcotest.check outcomes "completed" [ (id, J.Completed) ] (drain r);
      Alcotest.(check (list (pair int string)))
        "run once, with its payload"
        [ (1, "hello") ]
        !seen;
      check_bool "finished" true (Option.is_some (find conn id).finished_at);
      J.Runner.stop r)

let test_retry_waits_the_backoff_within_its_spread () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text "flaky" in
      let id = enqueue conn ~now:(now ()) kind "x" in
      let r =
        runner ~now target
          [ J.handle kind (fun _ _ -> Error (J.Retry "upstream down")) ]
      in
      List.iter
        (fun (attempt, base) ->
          let before = now () in
          Alcotest.check outcomes
            (Printf.sprintf "attempt %d retried" attempt)
            [ (id, J.Available) ]
            (drain r);
          let info = find conn id in
          let waited =
            Ptime.Span.to_float_s (Ptime.diff info.scheduled_at before)
          in
          check_bool
            (Printf.sprintf "attempt %d waits %gs, within a tenth of %ds"
               attempt waited base)
            true
            (waited >= float_of_int base *. 0.9
            && waited <= float_of_int base *. 1.1);
          check_int "its reason kept" attempt (List.length info.errors);
          at := info.scheduled_at)
        [ (1, 15); (2, 30); (3, 60) ];
      Alcotest.(check (list string))
        "every reason, in order"
        [ "upstream down"; "upstream down"; "upstream down" ]
        (List.map (fun (f : J.failed) -> f.reason) (find conn id).errors);
      J.Runner.stop r)

let test_retry_in_waits_what_it_names () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "limited" in
      let id = enqueue conn ~now:(now ()) kind "x" in
      let r =
        runner ~now target
          [
            J.handle kind (fun _ _ ->
                Error (J.Retry_in (Mtime.Span.(7 * s), "rate limited")));
          ]
      in
      ignore (drain r);
      Alcotest.check instant "seven seconds on"
        (plus (now ()) Mtime.Span.(7 * s))
        (find conn id).scheduled_at;
      J.Runner.stop r)

let test_the_last_attempt_discards () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text ~max_attempts:2 "doomed" in
      let id = enqueue conn ~now:(now ()) kind "x" in
      let r =
        runner ~now target [ J.handle kind (fun _ _ -> Error (J.Retry "no")) ]
      in
      ignore (drain r);
      at := plus !at Mtime.Span.min;
      Alcotest.check outcomes "discarded" [ (id, J.Discarded) ] (drain r);
      let info = find conn id in
      check_int "after both" 2 info.attempt;
      check_int "both reasons kept" 2 (List.length info.errors);
      J.Runner.stop r)

let test_discard_uses_no_attempt () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "hopeless" in
      let id = enqueue conn ~now:(now ()) kind "x" in
      let r =
        runner ~now target
          [ J.handle kind (fun _ _ -> Error (J.Discard "no engine")) ]
      in
      Alcotest.check outcomes "discarded at once"
        [ (id, J.Discarded) ]
        (drain r);
      let info = find conn id in
      check_int "its attempt handed back" 0 info.attempt;
      Alcotest.(check (list instant))
        "and when, read back from its written milliseconds"
        [ now () ]
        (List.map (fun (f : J.failed) -> f.at) info.errors);
      Alcotest.(check (list string))
        "and why" [ "no engine" ]
        (List.map (fun (f : J.failed) -> f.reason) info.errors);
      J.Runner.stop r)

exception Upstream of string

let test_a_raise_is_a_retry_named_by_its_constructor () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "raises" in
      let id = enqueue conn ~now:(now ()) kind "x" in
      let r =
        runner ~now target
          [ J.handle kind (fun _ _ -> raise (Upstream "a secret")) ]
      in
      Alcotest.check outcomes "retried" [ (id, J.Available) ] (drain r);
      match (find conn id).errors with
      | [ f ] ->
          check_bool "named by its constructor" true
            (String.ends_with ~suffix:"Upstream raised" f.reason);
          check_bool "never its argument" false
            (String.length f.reason >= 8
            &&
            let rec has i =
              i + 8 <= String.length f.reason
              && (String.equal (String.sub f.reason i 8) "a secret"
                 || has (i + 1))
            in
            has 0);
          J.Runner.stop r
      | _ -> Alcotest.fail "one reason")

let test_a_timeout_is_a_failure () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text ~timeout:Mtime.Span.(200 * ms) "slow" in
      let id = enqueue conn ~now:(now ()) kind "x" in
      let r =
        runner ~now target
          [
            J.handle kind (fun _ _ ->
                sleep Mtime.Span.(5 * s);
                Ok ());
          ]
      in
      Alcotest.check outcomes "retried" [ (id, J.Available) ] (drain r);
      Alcotest.(check (list string))
        "timed out"
        [ "timed out after 200ms" ]
        (List.map (fun (f : J.failed) -> f.reason) (find conn id).errors);
      J.Runner.stop r)

let test_a_payload_that_no_longer_decodes_is_discarded () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let old = text "shape" in
      let id = enqueue conn ~now:(now ()) old "a string" in
      let changed = J.Kind.make "shape" (one "note" Wiretype.int) in
      let r = runner ~now target [ J.handle changed done_ ] in
      Alcotest.check outcomes "discarded" [ (id, J.Discarded) ] (drain r);
      J.Runner.stop r)

let test_an_expired_job_is_discarded_unrun () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text "brief" in
      let ran = ref false in
      let id =
        enqueue conn ~now:(now ())
          ~expires_at:(plus (now ()) Mtime.Span.s)
          kind "x"
      in
      at := plus !at Mtime.Span.(2 * s);
      let r =
        runner ~now target
          [
            J.handle kind (fun _ _ ->
                ran := true;
                Ok ());
          ]
      in
      Alcotest.check outcomes "discarded" [ (id, J.Discarded) ] (drain r);
      check_bool "unrun" false !ran;
      Alcotest.(check (list string))
        "expired" [ "expired" ]
        (List.map (fun (f : J.failed) -> f.reason) (find conn id).errors);
      J.Runner.stop r)

let test_a_kind_not_kept_is_deleted_on_completion () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text ~keep:false "secret" in
      let id = enqueue conn ~now:(now ()) kind "x" in
      let r = runner ~now target [ J.handle kind done_ ] in
      Alcotest.check outcomes "completed" [ (id, J.Completed) ] (drain r);
      check_bool "and gone" true (Option.is_none (ok "find" (J.find conn id)));
      J.Runner.stop r)

let test_a_kind_nobody_handles_is_left_alone () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let mine = text "mine" and theirs = text "theirs" in
      let id = enqueue conn ~now:(now ()) theirs "x" in
      let r = runner ~now target [ J.handle mine done_ ] in
      Alcotest.check outcomes "nothing ran" [] (drain r);
      Alcotest.check state "still waiting" J.Available (find conn id).state;
      J.Runner.stop r)

let test_order_is_priority_then_instant_then_enqueueing () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "ordered" in
      let seen = ref [] in
      let e ?priority ?at arg =
        ignore (enqueue conn ~now:(now ()) ?priority ?at kind arg)
      in
      e ~priority:5 "late priority";
      e
        ~at:
          (match Ptime.sub_span (now ()) (Ptime.Span.of_int_s 1) with
          | Some t -> t
          | None -> Alcotest.fail "a second before now")
        "earlier";
      e "first enqueued";
      e "second enqueued";
      let r =
        runner ~now target
          [
            J.handle kind (fun _ arg ->
                seen := arg :: !seen;
                Ok ());
          ]
      in
      ignore (drain r);
      Alcotest.(check (list string))
        "in order"
        [ "earlier"; "first enqueued"; "second enqueued"; "late priority" ]
        (List.rev !seen);
      J.Runner.stop r)

(* ------------------------------------------------------------------ *)
(* An operator's hand *)

let test_cancel_and_retry () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "manual" in
      let waiting = enqueue conn ~now:(now ()) kind "w" in
      check_bool "cancelled" true
        (ok "cancel" (J.cancel conn ~now:(now ()) waiting));
      let fails = enqueue conn ~now:(now ()) ~unique:"k" kind "f" in
      let r =
        runner ~now target
          [
            J.handle kind (fun _ arg ->
                if String.equal arg "f" then Error (J.Discard "broken")
                else Ok ());
          ]
      in
      Alcotest.check outcomes "only the one not cancelled ran"
        [ (fails, J.Discarded) ]
        (drain r);
      check_bool "a finished job is not cancelled" false
        (ok "cancel" (J.cancel conn ~now:(now ()) fails));
      (* Put back, from its first attempt, its reasons kept. *)
      (match ok "retry" (J.retry conn ~now:(now ()) fails) with
      | Some id -> check_bool "itself" true (J.Id.equal id fails)
      | None -> Alcotest.fail "not retried");
      let info = find conn fails in
      Alcotest.check state "waiting again" J.Available info.state;
      check_int "from its first attempt" 0 info.attempt;
      check_int "its reason kept" 1 (List.length info.errors);
      check_bool "a waiting job is not retried" true
        (Option.is_none (ok "retry" (J.retry conn ~now:(now ()) fails)));
      (* Discarded again, and meanwhile the key asked again: the retry is
         the job already waiting. *)
      ignore (drain r);
      let fresh = enqueue conn ~now:(now ()) ~unique:"k" kind "fresh" in
      (match ok "retry" (J.retry conn ~now:(now ()) fails) with
      | Some id -> check_bool "the waiting one" true (J.Id.equal id fresh)
      | None -> Alcotest.fail "no answer");
      Alcotest.check state "the retried row left finished" J.Discarded
        (find conn fails).state;
      ignore (ok "retry" (J.retry conn ~now:(now ()) waiting));
      Alcotest.check state "a cancelled job retried" J.Available
        (find conn waiting).state;
      J.Runner.stop r)

(* ------------------------------------------------------------------ *)
(* Runners *)

let test_two_runners_complete_every_job_once () =
  with_table (fun target conn ->
      let n = 1000 in
      let kind = J.Kind.make "count" (one "count" Wiretype.int) in
      let seen = Hashtbl.create n in
      let handler _ i =
        Hashtbl.replace seen i
          (1 + Option.value (Hashtbl.find_opt seen i) ~default:0);
        Ok ()
      in
      let a =
        runner ~now:real_now
          ~poll:Mtime.Span.(100 * ms)
          ~queues:[ ("default", 8) ]
          target
          [ J.handle kind handler ]
      and b =
        runner ~now:real_now
          ~poll:Mtime.Span.(100 * ms)
          ~queues:[ ("default", 8) ]
          target
          [ J.handle kind handler ]
      in
      J.Runner.start a;
      J.Runner.start b;
      (match
         Pg.Transaction.within conn (fun c ->
             let rec go i =
               if i = n then Ok ()
               else
                 match J.enqueue c ~now:(real_now ()) kind i with
                 | Ok _ -> go (i + 1)
                 | Error (#Rowtype.error as e) -> Error e
                 | Error (`Unencodable e) ->
                     Error (`Db (Wiretype.Unwritable.to_string e))
                 | Error (`Bad_priority _) -> Error (`Db "priority")
             in
             go 0)
       with
      | Ok () -> ()
      | Error (`Not_committed m) -> Alcotest.failf "not committed: %s" m
      | Error (#Rowtype.error as e) ->
          Alcotest.failf "enqueue: %s" (Rowtype.error_to_string e));
      eventually
        ~within:Mtime.Span.(30 * s)
        "every job completed"
        (fun () ->
          match ok "counts" (J.counts conn) with
          | [ (_, J.Completed, c) ] -> c = n
          | _ -> false);
      J.Runner.stop a;
      J.Runner.stop b;
      check_int "every job seen" n (Hashtbl.length seen);
      check_bool "each once" true
        (Hashtbl.fold (fun _ c ok -> ok && c = 1) seen true))

let test_a_runner_killed_has_its_job_run_again () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text "long" in
      let id = enqueue conn ~now:(now ()) kind "x" in
      let started, began = Eio.Promise.create () in
      (try
         Eio.Switch.run (fun sw ->
             let r =
               match
                 J.Runner.create ~sw ~net:(Db_target.net ())
                   ~mono_clock:(Db_target.mono ()) ~now
                   ~poll:Mtime.Span.(100 * ms)
                   ~lease:Mtime.Span.(2 * s)
                   ~queues:[ ("default", 1) ]
                   [
                     J.handle kind (fun _ _ ->
                         Eio.Promise.resolve began ();
                         Eio.Fiber.await_cancel ());
                   ]
                   target
               with
               | Ok r -> r
               | Error e -> Alcotest.fail (J.Runner.refused_to_string e)
             in
             J.Runner.start r;
             Eio.Promise.await started;
             (* The process dies: no stop, nothing put back. *)
             Eio.Switch.fail sw Exit)
       with Exit -> ());
      Alcotest.check state "left running" J.Running (find conn id).state;
      at := plus !at Mtime.Span.(3 * s);
      let b = runner ~now target [ J.handle kind done_ ] in
      Alcotest.check outcomes "run again by another"
        [ (id, J.Completed) ]
        (drain b);
      let info = find conn id in
      check_int "its first attempt counted" 2 info.attempt;
      Alcotest.(check (list string))
        "and said why" [ "lease lapsed" ]
        (List.map (fun (f : J.failed) -> f.reason) info.errors);
      J.Runner.stop b)

let test_a_lease_taken_changes_nothing_and_stops_the_job () =
  with_table (fun target conn ->
      let kind = text "held" in
      let id = enqueue conn ~now:(real_now ()) kind "x" in
      let started, began = Eio.Promise.create () in
      let release, go = Eio.Promise.create () in
      let stopped = ref false in
      let r =
        runner ~now:real_now
          ~poll:Mtime.Span.(100 * ms)
          ~lease:Mtime.Span.(800 * ms)
          target
          [
            J.handle kind (fun _ _ ->
                Eio.Promise.resolve began ();
                try
                  Eio.Promise.await release;
                  Ok ()
                with Eio.Cancel.Cancelled _ as e ->
                  stopped := true;
                  raise e);
          ]
      in
      J.Runner.start r;
      Eio.Promise.await started;
      Db_target.exec conn
        (Printf.sprintf
           "update spool_jobs set runner = 'somebody else' where id = %s"
           (J.Id.to_string id));
      eventually ~within:Mtime.Span.s "the job stopped at the next heartbeat"
        (fun () -> !stopped);
      Eio.Promise.resolve go ();
      sleep Mtime.Span.(300 * ms);
      let info = find conn id in
      Alcotest.check state "still the other's" J.Running info.state;
      check_int "nothing recorded" 0 (List.length info.errors);
      J.Runner.stop r)

let test_a_runner_cut_off_stops_its_job_before_the_lease_ends () =
  with_table (fun target conn ->
      let kind = text "held" in
      let id = enqueue conn ~now:(real_now ()) kind "x" in
      let started, began = Eio.Promise.create () in
      let stopped_after = ref None in
      let lease = Mtime.Span.(1200 * ms) in
      let r =
        runner ~now:real_now
          ~poll:Mtime.Span.(100 * ms)
          ~lease target
          [
            J.handle kind (fun _ _ ->
                let t0 = mono_now () in
                Eio.Promise.resolve began ();
                try Eio.Fiber.await_cancel ()
                with Eio.Cancel.Cancelled _ as e ->
                  stopped_after := Some (Mtime.span t0 (mono_now ()));
                  raise e);
          ]
      in
      J.Runner.start r;
      Eio.Promise.await started;
      (* The row locked, so every renewal hangs as an unreachable database
         would. *)
      let blocker = Db_target.connect target in
      Db_target.exec blocker "begin";
      Db_target.exec blocker
        (Printf.sprintf "select id from spool_jobs where id = %s for update"
           (J.Id.to_string id));
      eventually
        ~within:Mtime.Span.(2 * s)
        "the job stopped"
        (fun () -> Option.is_some !stopped_after);
      (match !stopped_after with
      | Some took ->
          check_bool
            (Format.asprintf "within the lease (%a)" Mtime.Span.pp took)
            true
            (Mtime.Span.is_shorter took ~than:lease)
      | None -> ());
      Db_target.exec blocker "rollback";
      Pg.close blocker;
      J.Runner.stop r)

let test_a_notification_wakes_a_sleeping_queue () =
  with_table (fun target conn ->
      let kind = text "prompt" in
      let ran = ref false in
      let r =
        runner ~now:real_now
          ~poll:Mtime.Span.(10 * s)
          target
          [
            J.handle kind (fun _ _ ->
                ran := true;
                Ok ());
          ]
      in
      J.Runner.start r;
      sleep Mtime.Span.(500 * ms);
      ignore (enqueue conn ~now:(real_now ()) kind "x");
      eventually
        ~within:Mtime.Span.(2 * s)
        "run long before the poll"
        (fun () -> !ran);
      J.Runner.stop r)

(* The listener's driver sends a heartbeat after ten seconds of silence; a
   runner idle past it must still be standing, and still hear. *)
let test_a_runner_idle_past_the_heartbeat_still_runs_jobs () =
  with_table (fun target conn ->
      let kind = text "later" in
      let ran = ref false in
      let r =
        runner ~now:real_now
          ~poll:Mtime.Span.(30 * s)
          target
          [
            J.handle kind (fun _ _ ->
                ran := true;
                Ok ());
          ]
      in
      J.Runner.start r;
      sleep Mtime.Span.(12 * s);
      ignore (enqueue conn ~now:(real_now ()) kind "x");
      eventually
        ~within:Mtime.Span.(3 * s)
        "heard, after the heartbeat"
        (fun () -> !ran);
      J.Runner.stop r)

let test_jobs_run_without_the_listener () =
  with_table (fun target conn ->
      let kind = text "polled" in
      let ran = ref false in
      let r =
        runner ~now:real_now
          ~poll:Mtime.Span.(300 * ms)
          target
          [
            J.handle kind (fun _ _ ->
                ran := true;
                Ok ());
          ]
      in
      J.Runner.start r;
      sleep Mtime.Span.(500 * ms);
      Db_target.exec conn
        "select pg_terminate_backend(pid) from pg_stat_activity where datname \
         = current_database() and query like 'LISTEN%'";
      ignore (enqueue conn ~now:(real_now ()) kind "x");
      eventually ~within:Mtime.Span.(3 * s) "run by the poll" (fun () -> !ran);
      J.Runner.stop r)

let test_stop_puts_an_interrupted_job_back () =
  with_table (fun target conn ->
      let kind = text "endless" in
      let id = enqueue conn ~now:(real_now ()) kind "x" in
      let started, began = Eio.Promise.create () in
      let r =
        runner ~now:real_now
          ~poll:Mtime.Span.(100 * ms)
          target
          [
            J.handle kind (fun _ _ ->
                Eio.Promise.resolve began ();
                Eio.Fiber.await_cancel ());
          ]
      in
      J.Runner.start r;
      Eio.Promise.await started;
      let t0 = mono_now () in
      J.Runner.stop ~grace:Mtime.Span.(200 * ms) r;
      check_bool "within the grace and a statement" true
        (Mtime.Span.is_shorter
           (Mtime.span t0 (mono_now ()))
           ~than:Mtime.Span.(2 * s));
      let info = find conn id in
      Alcotest.check state "put back" J.Available info.state;
      check_int "its attempt not counted" 0 info.attempt;
      check_int "and no failure recorded" 0 (List.length info.errors))

let test_finished_rows_are_pruned_by_retention () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text "old" in
      let good = enqueue conn ~now:(now ()) kind "good" in
      let bad = enqueue conn ~now:(now ()) kind "bad" in
      let handler _ arg =
        if String.equal arg "bad" then Error (J.Discard "no") else Ok ()
      in
      let r = runner ~now target [ J.handle kind handler ] in
      ignore (drain r);
      J.Runner.stop r;
      at := plus !at Mtime.Span.(2 * day);
      let pruner = runner ~now target [ J.handle kind handler ] in
      J.Runner.start pruner;
      eventually "the completed one pruned" (fun () ->
          Option.is_none (ok "find" (J.find conn good)));
      check_bool "the discarded one kept a fortnight" true
        (Option.is_some (ok "find" (J.find conn bad)));
      J.Runner.stop pruner)

(* A database whose table spool's migrations have not made is found at
   start, with what to run, rather than by the first job. *)
let test_create_refuses_an_unmigrated_database () =
  Db_target.with_postgres (fun target ->
      match
        J.Runner.create ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
          ~mono_clock:(Db_target.mono ()) ~now:real_now
          ~queues:[ ("default", 1) ]
          [] target
      with
      | Error (J.Runner.Unmigrated _ as r) ->
          let said = J.Runner.refused_to_string r in
          Alcotest.(check bool)
            "it says what to run" true
            (contains said "rowtype-migrate up --source spool")
      | Error r ->
          Alcotest.failf "refused otherwise: %s" (J.Runner.refused_to_string r)
      | Ok _ -> Alcotest.fail "a runner started without its table")

let test_create_refuses_what_it_cannot_honour () =
  with_table (fun target _ ->
      let a = text "a" and b = text ~queue:"elsewhere" "b" in
      let refused queues handlers =
        match
          J.Runner.create ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
            ~mono_clock:(Db_target.mono ()) ~now:real_now ~queues handlers
            target
        with
        | Ok r ->
            J.Runner.stop r;
            None
        | Error e -> Some e
      in
      check_bool "two handlers of one kind" true
        (match
           refused [ ("default", 1) ] [ J.handle a done_; J.handle a done_ ]
         with
        | Some (J.Runner.Two_handlers "a") -> true
        | _ -> false);
      check_bool "a handler for a queue it does not run" true
        (match refused [ ("default", 1) ] [ J.handle b done_ ] with
        | Some (J.Runner.Unrun_queue "b") -> true
        | _ -> false);
      check_bool "a concurrency under one" true
        (match refused [ ("default", 0) ] [ J.handle a done_ ] with
        | Some (J.Runner.No_concurrency "default") -> true
        | _ -> false))

(* Every line logged at debug while a job with a secret in its payload is
   enqueued, fails, raises and completes -- but the TLS library's own
   transcript, which is the records themselves and so the application's to
   cap, as the driver's suite leaves it. *)
let test_no_payload_reaches_a_log () =
  with_table (fun target conn ->
      let lines = ref [] in
      let previous = Logs.reporter () and level = Logs.level () in
      let transcript src =
        match Logs.Src.name src with
        | "tls.tracing" | "handshake" -> true
        | _ -> false
      in
      let report src _level ~over k msgf =
        msgf (fun ?header:_ ?tags:_ fmt ->
            Format.kasprintf
              (fun line ->
                if not (transcript src) then lines := line :: !lines;
                over ();
                k ())
              fmt)
      in
      Logs.set_reporter { Logs.report };
      Logs.set_level (Some Logs.Debug);
      Fun.protect
        ~finally:(fun () ->
          Logs.set_reporter previous;
          Logs.set_level level)
        (fun () ->
          let now, at = clock () in
          let secret = "s3cr3t-payload" in
          let kind = text "private" in
          ignore (enqueue conn ~now:(now ()) kind secret);
          let calls = ref 0 in
          let r =
            runner ~now target
              [
                J.handle kind (fun _ _ ->
                    incr calls;
                    match !calls with
                    | 1 -> Error (J.Retry "upstream")
                    | 2 -> raise (Upstream "x")
                    | _ -> Ok ());
              ]
          in
          ignore (drain r);
          at := plus !at Mtime.Span.min;
          ignore (drain r);
          at := plus !at Mtime.Span.min;
          ignore (drain r);
          J.Runner.stop r;
          check_bool "something was logged" true (!lines <> []);
          List.iter
            (fun line ->
              let n = String.length secret in
              let rec has i =
                i + n <= String.length line
                && (String.equal (String.sub line i n) secret || has (i + 1))
              in
              if has 0 then Alcotest.failf "a payload in a log line: %s" line)
            !lines))

(* ------------------------------------------------------------------ *)
(* An operator's hand: queues, runners, statistics *)

let queue_named conn name =
  match
    List.find_opt
      (fun (q : J.Queue.t) -> String.equal q.name name)
      (ok "queues" (J.Queue.list conn))
  with
  | Some q -> q
  | None -> Alcotest.failf "no queue %s" name

(* A pause is the table's, so it holds for every runner, one made after it
   among them, until it is resumed. *)
let test_a_paused_queue_is_claimed_by_no_runner () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "note" in
      let id = enqueue conn ~now:(now ()) kind "x" in
      ok "pause" (J.Queue.pause conn ~now:(now ()) "default");
      check_bool "paused" true (queue_named conn "default").paused;
      let r = runner ~now target [ J.handle kind done_ ] in
      Alcotest.check outcomes "nothing claimed" [] (drain r);
      J.Runner.stop r;
      let r = runner ~now target [ J.handle kind done_ ] in
      Alcotest.check outcomes "nor by a runner made since" [] (drain r);
      ok "resume" (J.Queue.resume conn ~now:(now ()) "default");
      check_bool "resumed" false (queue_named conn "default").paused;
      Alcotest.check outcomes "then run" [ (id, J.Completed) ] (drain r);
      J.Runner.stop r)

(* A queue a runner names has its row, unpaused, without anyone asking. *)
let test_a_queue_is_listed_once_a_runner_names_it () =
  with_table (fun target conn ->
      let now, _ = clock () in
      Alcotest.(check (list string))
        "none before" []
        (List.map
           (fun (q : J.Queue.t) -> q.name)
           (ok "queues" (J.Queue.list conn)));
      let r = runner ~now ~queues:[ ("mail", 2); ("default", 1) ] target [] in
      Alcotest.(check (list string))
        "each, in order of name" [ "default"; "mail" ]
        (List.map
           (fun (q : J.Queue.t) -> q.name)
           (ok "queues" (J.Queue.list conn)));
      check_bool "unpaused" false (queue_named conn "mail").paused;
      J.Runner.stop r)

let test_a_started_runner_is_listed_until_it_stops () =
  with_table (fun target conn ->
      let r =
        runner ~now:real_now
          ~lease:Mtime.Span.(2 * s)
          ~queues:[ ("mail", 3) ]
          target []
      in
      J.Runner.start r;
      eventually "listed" (fun () ->
          match ok "runners" (J.Runner.list conn) with
          | [ (i : J.Runner.info) ] ->
              Alcotest.(check (list (pair string int)))
                "its queues and their slots"
                [ ("mail", 3) ]
                i.queues;
              check_int "its process" (Unix.getpid ()) i.pid;
              true
          | _ -> false);
      J.Runner.stop r;
      Alcotest.(check int)
        "gone once stopped" 0
        (List.length (ok "runners" (J.Runner.list conn))))

let test_each_attempt_is_counted_by_its_second () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "note" in
      let _ = enqueue conn ~now:(now ()) kind "ok" in
      let _ = enqueue conn ~now:(now ()) kind "ok" in
      let _ = enqueue conn ~now:(now ()) kind "again" in
      let _ = enqueue conn ~now:(now ()) kind "never" in
      let r =
        runner ~now target
          [
            J.handle kind (fun _ arg ->
                match arg with
                | "again" -> Error (J.Retry "later")
                | "never" -> Error (J.Discard "no")
                | _ -> Ok ());
          ]
      in
      ignore (drain r);
      let a_minute_ago =
        Option.value ~default:(now ())
          (Ptime.sub_span (now ()) (Ptime.Span.of_int_s 60))
      in
      let stats = ok "stats" (J.Stats.since conn a_minute_ago) in
      let count is =
        List.fold_left
          (fun n (s : J.Stats.t) -> if is s.outcome then n + s.count else n)
          0 stats
      in
      check_int "completed" 2
        (count (function
          | J.Stats.Completed -> true
          | Retried | Discarded -> false));
      check_int "retried" 1
        (count (function
          | J.Stats.Retried -> true
          | Completed | Discarded -> false));
      check_int "discarded" 1
        (count (function
          | J.Stats.Discarded -> true
          | Completed | Retried -> false));
      check_bool "by queue and kind" true
        (List.for_all
           (fun (s : J.Stats.t) ->
             String.equal s.queue "default" && String.equal s.kind "note")
           stats);
      J.Runner.stop r)

let test_delete_removes_any_job_but_a_running_one () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "note" in
      let waiting = enqueue conn ~now:(now ()) kind "w" in
      check_bool "a waiting job deleted" true
        (ok "delete" (J.delete conn ~now:(now ()) waiting));
      check_bool "gone" true (Option.is_none (ok "find" (J.find conn waiting)));
      let finished = enqueue conn ~now:(now ()) kind "f" in
      let r = runner ~now target [ J.handle kind done_ ] in
      ignore (drain r);
      check_bool "a finished job deleted" true
        (ok "delete" (J.delete conn ~now:(now ()) finished));
      check_bool "an unknown id is no deletion" false
        (ok "delete" (J.delete conn ~now:(now ()) finished));
      let started, release = Eio.Promise.create () in
      let held, let_go = Eio.Promise.create () in
      let busy = text "busy" in
      let running = enqueue conn ~now:(now ()) busy "r" in
      let r2 =
        runner ~now:real_now target
          [
            J.handle busy (fun _ _ ->
                Eio.Promise.resolve release ();
                Eio.Promise.await held;
                Ok ());
          ]
      in
      J.Runner.start r2;
      Eio.Promise.await started;
      check_bool "a running job is not" false
        (ok "delete" (J.delete conn ~now:(now ()) running));
      Eio.Promise.resolve let_go ();
      J.Runner.stop r;
      J.Runner.stop r2)

(* ------------------------------------------------------------------ *)
(* Limits across runners *)

let set_limits ?running ?rate ?(per_partition = false) conn ~now name =
  match J.Queue.set_limits conn ~now ~running ~rate ~per_partition name with
  | Ok () -> ()
  | Error (#Rowtype.error as e) ->
      Alcotest.failf "set_limits: %s" (Rowtype.error_to_string e)
  | Error (`Bad_limit m) -> Alcotest.failf "set_limits: %s" m

let by_customer =
  Wiretype.Object.map (fun customer n -> (customer, n))
  |> Wiretype.Object.mem "customer" Wiretype.string ~enc:fst
  |> Wiretype.Object.mem "n" Wiretype.int ~enc:snd
  |> Wiretype.Object.finish

let test_a_limit_holds_across_runners () =
  with_table (fun target conn ->
      let kind = J.Kind.make ~queue:"api" "call" (one "n" Wiretype.int) in
      set_limits conn ~now:(real_now ()) ~running:2 "api";
      let current = Atomic.make 0 and most = Atomic.make 0 in
      let handler _ _ =
        let n = 1 + Atomic.fetch_and_add current 1 in
        let rec raise_to () =
          let m = Atomic.get most in
          if n > m && not (Atomic.compare_and_set most m n) then raise_to ()
        in
        raise_to ();
        sleep Mtime.Span.(100 * ms);
        Atomic.decr current;
        Ok ()
      in
      let start () =
        let r =
          runner ~now:real_now
            ~poll:Mtime.Span.(50 * ms)
            ~queues:[ ("api", 4) ]
            target
            [ J.handle kind handler ]
        in
        J.Runner.start r;
        r
      in
      let a = start () and b = start () in
      for i = 1 to 8 do
        ignore (enqueue conn ~now:(real_now ()) kind i : J.Id.t)
      done;
      eventually
        ~within:Mtime.Span.(20 * s)
        "every job completed"
        (fun () ->
          match ok "counts" (J.counts conn) with
          | [ (_, J.Completed, 8) ] -> true
          | _ -> false);
      J.Runner.stop a;
      J.Runner.stop b;
      check_bool "never more than two at once, across both" true
        (Atomic.get most <= 2))

let test_a_rate_holds_over_its_period () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text ~queue:"api" "call" in
      set_limits conn ~now:(now ())
        ~rate:{ attempts = 3; per = Mtime.Span.min }
        "api";
      for _ = 1 to 5 do
        ignore (enqueue conn ~now:(now ()) kind "x" : J.Id.t)
      done;
      let r =
        runner ~now ~queues:[ ("api", 8) ] target [ J.handle kind done_ ]
      in
      check_int "three in the minute" 3 (List.length (drain r));
      check_int "none more within it" 0 (List.length (drain r));
      at := plus !at Mtime.Span.(61 * s);
      check_int "the rest in the next" 2 (List.length (drain r));
      J.Runner.stop r)

(* Partitions are taken in turns: each one's first job, then each one's
   second, so one partition's many does not keep another's few waiting. *)
let test_partitions_are_claimed_in_turns () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = J.Kind.make ~queue:"api" ~partition:fst "call" by_customer in
      set_limits conn ~now:(now ()) ~per_partition:true "api";
      let a1 = enqueue conn ~now:(now ()) kind ("a", 1) in
      let a2 = enqueue conn ~now:(now ()) kind ("a", 2) in
      let a3 = enqueue conn ~now:(now ()) kind ("a", 3) in
      let b1 = enqueue conn ~now:(now ()) kind ("b", 1) in
      let r =
        runner ~now ~queues:[ ("api", 8) ] target [ J.handle kind done_ ]
      in
      Alcotest.check outcomes "b's one before a's second"
        [
          (a1, J.Completed);
          (b1, J.Completed);
          (a2, J.Completed);
          (a3, J.Completed);
        ]
        (drain r);
      J.Runner.stop r)

let test_a_limit_per_partition () =
  with_table (fun target conn ->
      let kind = J.Kind.make ~queue:"api" ~partition:fst "call" by_customer in
      set_limits conn ~now:(real_now ()) ~running:1 ~per_partition:true "api";
      let held, let_go = Eio.Promise.create () in
      let r =
        runner ~now:real_now
          ~poll:Mtime.Span.(50 * ms)
          ~queues:[ ("api", 8) ]
          target
          [
            J.handle kind (fun _ _ ->
                Eio.Promise.await held;
                Ok ());
          ]
      in
      J.Runner.start r;
      List.iter
        (fun job -> ignore (enqueue conn ~now:(real_now ()) kind job : J.Id.t))
        [ ("a", 1); ("a", 2); ("a", 3); ("b", 1) ];
      let running () =
        List.fold_left
          (fun n (_, st, c) ->
            match st with
            | J.Running -> n + c
            | Available | Blocked | Completed | Discarded | Cancelled -> n)
          0
          (ok "counts" (J.counts conn))
      in
      eventually "one of each running" (fun () -> running () = 2);
      sleep Mtime.Span.(300 * ms);
      check_int "and no more, with slots to spare" 2 (running ());
      Eio.Promise.resolve let_go ();
      eventually "every job completed" (fun () ->
          match ok "counts" (J.counts conn) with
          | [ (_, J.Completed, 4) ] -> true
          | _ -> false);
      J.Runner.stop r)

let test_a_limit_that_cannot_hold_is_refused () =
  with_table (fun _ conn ->
      let refused ?running ?rate () =
        match
          J.Queue.set_limits conn ~now:(real_now ()) ~running ~rate
            ~per_partition:false "api"
        with
        | Error (`Bad_limit _) -> true
        | Ok () | Error _ -> false
      in
      check_bool "no slot" true (refused ~running:0 ());
      check_bool "no attempt in a period" true
        (refused ~rate:{ attempts = 0; per = Mtime.Span.min } ());
      check_bool "a period of nothing" true
        (refused ~rate:{ attempts = 1; per = Mtime.Span.zero } ());
      check_bool "a limit that can hold is not" false (refused ~running:1 ()))

(* ------------------------------------------------------------------ *)
(* Schedules *)

let utc y mo d h mi =
  match Ptime.of_date_time ((y, mo, d), ((h, mi, 0), 0)) with
  | Some t -> t
  | None -> Alcotest.fail "no such instant"

let next sc after =
  match J.Schedule.next sc ~after with
  | Some t -> t
  | None -> Alcotest.fail "no next tick"

let schedule ?(name = "tick") ?(zone = "UTC") cron kind payload =
  J.Schedule.make ~name ~cron ~zone kind payload

(* London's clock goes forward at 01:00 GMT on 29 March 2026 and back at
   01:00 GMT on 25 October 2026. *)
let test_a_tick_is_local_across_clock_changes () =
  let kind = text "report" in
  let eight = schedule ~zone:"Europe/London" "0 8 * * *" kind "x" in
  Alcotest.check instant "08:00 GMT in winter" (utc 2026 3 28 8 0)
    (next eight (utc 2026 3 28 0 0));
  Alcotest.check instant "08:00 BST the day after, 07:00 UTC"
    (utc 2026 3 29 7 0)
    (next eight (utc 2026 3 28 9 0));
  let skipped = schedule ~zone:"Europe/London" "30 1 * * *" kind "x" in
  Alcotest.check instant "a skipped 01:30 runs as the clock changes"
    (utc 2026 3 29 1 0)
    (next skipped (utc 2026 3 29 0 0));
  let first = next skipped (utc 2026 10 25 0 0) in
  Alcotest.check instant "a repeated 01:30 runs at its first"
    (utc 2026 10 25 0 30) first;
  Alcotest.check instant "and not again at its second" (utc 2026 10 26 1 30)
    (next skipped first)

let test_a_schedule_that_cannot_run_is_refused () =
  let kind = text "report" in
  let refused ?zone cron =
    match schedule ?zone cron kind "x" with
    | _ -> false
    | exception Invalid_argument _ -> true
  in
  check_bool "six fields" true (refused "0 0 * * * *");
  check_bool "a minute of sixty" true (refused "60 * * * *");
  check_bool "a backward range" true (refused "0 5-2 * * *");
  check_bool "the thirtieth of February" true (refused "0 0 30 2 *");
  check_bool "a zone the tz database has not" true
    (refused ~zone:"Mars/Olympus" "0 0 * * *");
  check_bool "steps, lists and Sunday as 7 read" false
    (refused "*/15 9-17/2 1,15 * 1-5,7");
  check_bool "an alias reads" false (refused "@daily");
  let both = schedule "0 0 13 * 5" kind "x" in
  Alcotest.check instant "both days restricted: either matches"
    (utc 2026 11 20 0 0)
    (next both (utc 2026 11 14 0 0))

(* Three runners hold one schedule; each drains as the clock passes ticks,
   and each tick is one job. Ticks missed are the latest alone. *)
let test_a_tick_is_one_job_across_runners () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text "report" in
      let ran = ref 0 in
      let sc = schedule "* * * * *" kind "nightly" in
      let start () =
        runner ~now ~schedules:[ sc ] target
          [
            J.handle kind (fun _ _ ->
                incr ran;
                Ok ());
          ]
      in
      let a = start () and b = start () and c = start () in
      List.iter (fun r -> ignore (drain r)) [ a; b; c ];
      check_int "nothing before its first tick" 0 !ran;
      at := plus !at Mtime.Span.min;
      List.iter (fun r -> ignore (drain r)) [ a; b; c ];
      check_int "its tick, once" 1 !ran;
      at := plus !at Mtime.Span.(10 * min);
      List.iter (fun r -> ignore (drain r)) [ a; b; c ];
      check_int "ten missed, the latest alone" 2 !ran;
      (match ok "schedules" (J.Schedule.list conn) with
      | [ (i : J.Schedule.info) ] ->
          check_bool "its next tick after now" true
            (Ptime.is_later i.next_at ~than:(now ()))
      | _ -> Alcotest.fail "one schedule");
      List.iter J.Runner.stop [ a; b; c ])

let only_schedule conn =
  match ok "schedules" (J.Schedule.list conn) with
  | [ (i : J.Schedule.info) ] -> i
  | _ -> Alcotest.fail "one schedule"

let test_run_now_enqueues_beside_the_ticks () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text "report" in
      let sc = schedule ~name:"daily" "0 3 * * *" kind "x" in
      let r = runner ~now ~schedules:[ sc ] target [ J.handle kind done_ ] in
      let before = (only_schedule conn).next_at in
      (match ok "run now" (J.Schedule.run_now conn ~now:(now ()) "daily") with
      | Some id -> Alcotest.check outcomes "run" [ (id, J.Completed) ] (drain r)
      | None -> Alcotest.fail "not enqueued");
      Alcotest.check instant "its next tick unmoved" before
        (only_schedule conn).next_at;
      check_bool "an unknown schedule is none" true
        (Option.is_none
           (ok "run now" (J.Schedule.run_now conn ~now:(now ()) "x")));
      J.Runner.stop r)

(* ------------------------------------------------------------------ *)
(* Unique for a period, and many at once *)

let test_a_key_holds_for_its_period_whatever_the_state () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text "digest" in
      let first =
        enqueue conn ~now:(now ()) ~unique:"kim" ~unique_for:Mtime.Span.hour
          kind "a"
      in
      let r = runner ~now target [ J.handle kind done_ ] in
      Alcotest.check outcomes "run" [ (first, J.Completed) ] (drain r);
      at := plus !at Mtime.Span.(30 * min);
      let again =
        enqueue conn ~now:(now ()) ~unique:"kim" ~unique_for:Mtime.Span.hour
          kind "b"
      in
      check_bool "within the hour, the completed job" true
        (J.Id.equal first again);
      Alcotest.check outcomes "and nothing more runs" [] (drain r);
      let other =
        enqueue conn ~now:(now ()) ~unique:"lee" ~unique_for:Mtime.Span.hour
          kind "c"
      in
      check_bool "another key is another job" false (J.Id.equal first other);
      at := plus !at Mtime.Span.(31 * min);
      let later_one =
        enqueue conn ~now:(now ()) ~unique:"kim" ~unique_for:Mtime.Span.hour
          kind "d"
      in
      check_bool "past the hour, a new job" false (J.Id.equal first later_one);
      J.Runner.stop r)

let test_a_period_without_a_key_holds_for_the_kind () =
  with_table (fun _ conn ->
      let now, _ = clock () in
      let kind = text "sync" in
      let a = enqueue conn ~now:(now ()) ~unique_for:Mtime.Span.hour kind "a" in
      let b = enqueue conn ~now:(now ()) ~unique_for:Mtime.Span.hour kind "b" in
      check_bool "one job of the kind in the hour" true (J.Id.equal a b))

(* A row whose key still holds outlives retention, and a kind that keeps
   nothing keeps the row and not the payload, until the period ends. *)
let test_a_held_key_outlives_retention_and_keep () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text ~keep:false "secret" in
      let id =
        enqueue conn ~now:(now ()) ~unique:"k"
          ~unique_for:Mtime.Span.(3 * day)
          kind "the secret"
      in
      let r = runner ~now target [ J.handle kind done_ ] in
      Alcotest.check outcomes "completed" [ (id, J.Completed) ] (drain r);
      check_bool "its row kept for the key" true
        (Option.is_some (ok "find" (J.find conn id)));
      at := plus !at Mtime.Span.(2 * day);
      check_bool "still the answer past retention" true
        (J.Id.equal id
           (enqueue conn ~now:(now ()) ~unique:"k"
              ~unique_for:Mtime.Span.(3 * day)
              kind "again"));
      J.Runner.stop r;
      let pruner =
        runner ~now:(fun () -> now ()) target [ J.handle kind done_ ]
      in
      J.Runner.start pruner;
      sleep Mtime.Span.(300 * ms);
      check_bool "not pruned while its key holds" true
        (Option.is_some (ok "find" (J.find conn id)));
      J.Runner.stop pruner;
      check_bool "its payload gone" true
        (match
           Pg.run conn
             (Rowtype.find ~params:Rowtype.int ~row:Rowtype.text
                "select payload::text from spool_jobs where id = $1")
             (match int_of_string_opt (J.Id.to_string id) with
             | Some n -> n
             | None -> Alcotest.fail "an id is a counter")
         with
        | Ok p -> not (contains p "secret")
        | Error _ -> false))

let test_many_are_enqueued_at_once () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = J.Kind.make "row" (one "row" Wiretype.int) in
      let ids =
        match
          Pg.Transaction.within conn (fun c ->
              J.enqueue_many c ~now:(now ()) kind (List.init 500 Fun.id))
        with
        | Ok ids -> ids
        | Error _ -> Alcotest.fail "enqueue_many"
      in
      check_int "an id each" 500 (List.length ids);
      let keyed =
        match
          Pg.Transaction.within conn (fun c ->
              J.enqueue_many c ~now:(now ())
                ~unique:(fun n -> string_of_int (n mod 3))
                kind [ 1; 2; 3; 4; 5; 6 ])
        with
        | Ok ids -> ids
        | Error _ -> Alcotest.fail "enqueue_many keyed"
      in
      check_int "one job a key" 3 (List.length keyed);
      let seen = ref 0 in
      let r =
        runner ~now target
          [
            J.handle kind (fun _ _ ->
                incr seen;
                Ok ());
          ]
      in
      ignore (drain r);
      check_int "every one run" 503 !seen;
      J.Runner.stop r)

(* ------------------------------------------------------------------ *)
(* Workflows *)

let enqueue_after conn ~now ~waits_for kind arg =
  match
    Pg.Transaction.within conn (fun c ->
        J.enqueue_after c ~now ~waits_for kind arg)
  with
  | Ok id -> id
  | Error _ -> Alcotest.fail "enqueue_after"

let many conn ~now kind args =
  match
    Pg.Transaction.within conn (fun c -> J.enqueue_many c ~now kind args)
  with
  | Ok ids -> ids
  | Error _ -> Alcotest.fail "enqueue_many"

let test_a_summary_runs_once_after_every_row () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let row = J.Kind.make "row" (one "row" Wiretype.int) in
      let summary = text "summary" in
      let rows = many conn ~now:(now ()) row [ 1; 2; 3 ] in
      let s = enqueue_after conn ~now:(now ()) ~waits_for:rows summary "done" in
      Alcotest.check state "blocked while rows wait" J.Blocked
        (find conn s).state;
      let order = ref [] in
      let r =
        runner ~now target
          [
            J.handle row (fun _ n ->
                order := string_of_int n :: !order;
                Ok ());
            J.handle summary (fun _ _ ->
                order := "summary" :: !order;
                Ok ());
          ]
      in
      ignore (drain r);
      Alcotest.(check (list string))
        "the summary last, once"
        [ "1"; "2"; "3"; "summary" ]
        (List.rev !order);
      J.Runner.stop r)

let test_a_failed_row_cancels_what_waits_on_it () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let row = J.Kind.make "row" (one "row" Wiretype.int) in
      let summary = text "summary" in
      let rows = many conn ~now:(now ()) row [ 1; 2 ] in
      let s = enqueue_after conn ~now:(now ()) ~waits_for:rows summary "s" in
      let after =
        enqueue_after conn ~now:(now ()) ~waits_for:[ s ] summary "a"
      in
      let r =
        runner ~now target
          [
            J.handle row (fun _ n ->
                if n = 2 then Error (J.Discard "bad") else Ok ());
            J.handle summary done_;
          ]
      in
      ignore (drain r);
      let cancelled id =
        let info = find conn id in
        Alcotest.check state "cancelled" J.Cancelled info.state;
        check_bool "saying which job" true
          (List.exists
             (fun (f : J.failed) -> contains f.reason "it waits for")
             info.errors)
      in
      cancelled s;
      cancelled after;
      J.Runner.stop r)

let test_what_a_job_waits_for_may_be_gone_or_done () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let gone = text ~keep:false "gone" in
      let next = text "next" in
      let g = enqueue conn ~now:(now ()) gone "g" in
      let r = runner ~now target [ J.handle gone done_; J.handle next done_ ] in
      ignore (drain r);
      let n = enqueue_after conn ~now:(now ()) ~waits_for:[ g ] next "n" in
      Alcotest.check state "a completed job no longer kept is done" J.Available
        (find conn n).state;
      let c = enqueue conn ~now:(now ()) next "c" in
      ignore (ok "cancel" (J.cancel conn ~now:(now ()) c));
      let w = enqueue_after conn ~now:(now ()) ~waits_for:[ c ] next "w" in
      Alcotest.check state "one waiting for a cancelled job is cancelled"
        J.Cancelled (find conn w).state;
      J.Runner.stop r)

let test_cancelling_a_job_cancels_what_waits_on_it () =
  with_table (fun _ conn ->
      let now, _ = clock () in
      let kind = text "step" in
      let a = enqueue conn ~now:(now ()) kind "a" in
      let b = enqueue_after conn ~now:(now ()) ~waits_for:[ a ] kind "b" in
      ignore (ok "cancel" (J.cancel conn ~now:(now ()) a));
      Alcotest.check state "cancelled with it" J.Cancelled (find conn b).state)

let test_a_workflow_is_its_jobs_and_their_edges () =
  with_table (fun _ conn ->
      let now, _ = clock () in
      let kind = text "step" in
      let a = enqueue conn ~now:(now ()) kind "a" in
      let b = enqueue conn ~now:(now ()) kind "b" in
      let c = enqueue_after conn ~now:(now ()) ~waits_for:[ a; b ] kind "c" in
      let _alone = enqueue conn ~now:(now ()) kind "alone" in
      let w = ok "workflow" (J.workflow conn b) in
      check_int "three jobs" 3 (List.length w.jobs);
      check_int "two edges" 2 (List.length w.edges);
      check_bool "c waits for a" true
        (List.exists (fun (j, o) -> J.Id.equal j c && J.Id.equal o a) w.edges))

(* ------------------------------------------------------------------ *)
(* What an operator's screen reads *)

let test_a_sensitive_payload_reaches_no_answer () =
  with_table (fun _ conn ->
      let now, _ = clock () in
      let secret =
        J.Kind.make ~sensitive:true "card" (one "card" Wiretype.string)
      in
      let plain = text "note" in
      let s = enqueue conn ~now:(now ()) secret "4111 1111 1111 1111" in
      let p = enqueue conn ~now:(now ()) plain "hello" in
      check_bool "not found" true (Option.is_none (find conn s).payload);
      check_bool "nor listed" true
        (List.for_all
           (fun (i : J.info) -> J.Id.equal i.id p || Option.is_none i.payload)
           (ok "jobs" (J.jobs conn ~limit:10)));
      Alcotest.(check (option string))
        "a plain one is" (Some {|{"note": "hello"}|}) (find conn p).payload)

let test_an_id_reads_back_as_it_was_written () =
  with_table (fun _ conn ->
      let now, _ = clock () in
      let id = enqueue conn ~now:(now ()) (text "note") "x" in
      let read = J.Id.of_string (J.Id.to_string id) in
      check_bool "read back" true
        (match read with Some r -> J.Id.equal r id | None -> false);
      List.iter
        (fun text ->
          check_bool ("not an id: " ^ text) true
            (Option.is_none (J.Id.of_string text)))
        [
          "";
          "0";
          "-1";
          "0x10";
          "1_000";
          " 1";
          "+1";
          "1e3";
          "99999999999999999999";
        ])

let test_jobs_are_listed_newest_first_a_page_at_a_time () =
  with_table (fun _ conn ->
      let now, _ = clock () in
      let a = text "a" and b = text ~queue:"other" "b" in
      let ids = List.init 5 (fun _ -> enqueue conn ~now:(now ()) a "x") in
      let other = enqueue conn ~now:(now ()) b "y" in
      let page = ok "jobs" (J.jobs conn ~kind:"a" ~limit:3) in
      let id_list = List.map (fun (i : J.info) -> J.Id.to_string i.id) in
      Alcotest.(check (list string))
        "newest first, of the kind"
        (id_list
           (List.filter_map
              (fun id -> J.find conn id |> Result.to_option |> Option.join)
              (List.rev ids)
           |> List.filteri (fun i _ -> i < 3)))
        (id_list page);
      let last =
        match List.rev page with
        | (i : J.info) :: _ -> i.id
        | [] -> Alcotest.fail "an empty page"
      in
      check_int "the rest below it" 2
        (List.length (ok "jobs" (J.jobs conn ~kind:"a" ~before:last ~limit:10)));
      check_int "by queue" 1
        (List.length (ok "jobs" (J.jobs conn ~queue:"other" ~limit:10)));
      ignore (ok "cancel" (J.cancel conn ~now:(now ()) other));
      check_int "by state" 1
        (List.length (ok "jobs" (J.jobs conn ~state:J.Cancelled ~limit:10)));
      Alcotest.(check (list (triple string state int)))
        "unfinished counts leave the cancelled out"
        [ ("default", J.Available, 5) ]
        (ok "counts" (J.counts ~finished:false conn)))

let test_a_runner_is_seen_at_each_heartbeat () =
  with_table (fun target conn ->
      let r =
        runner ~now:real_now
          ~lease:Mtime.Span.(2 * s)
          ~queues:[ ("mail", 1) ]
          target []
      in
      J.Runner.start r;
      let seen () =
        match ok "runners" (J.Runner.list conn) with
        | [ (i : J.Runner.info) ] -> Some i
        | _ -> None
      in
      eventually "listed" (fun () -> Option.is_some (seen ()));
      sleep Mtime.Span.(1500 * ms);
      (match seen () with
      | Some i ->
          check_bool "seen after it started" true
            (Ptime.is_later i.seen_at ~than:i.started_at)
      | None -> Alcotest.fail "gone while running");
      sleep Mtime.Span.(2500 * ms);
      check_bool "still listed past its lease" true (Option.is_some (seen ()));
      J.Runner.stop r)

let test_jobs_are_found_by_when_an_attempt_finished () =
  with_table (fun target conn ->
      let now, at = clock () in
      let kind = text "note" in
      let ok_early = enqueue conn ~now:(now ()) kind "ok" in
      let failing = enqueue conn ~now:(now ()) kind "fail" in
      let r =
        runner ~now target
          [
            J.handle kind (fun _ arg ->
                if String.equal arg "fail" then Error (J.Retry "not yet")
                else Ok ());
          ]
      in
      let start = now () in
      ignore (drain r);
      at := plus !at Mtime.Span.(2 * min);
      let ok_late = enqueue conn ~now:(now ()) kind "ok" in
      ignore (drain r);
      let first = (start, plus start Mtime.Span.min) in
      let ids which span =
        List.map
          (fun (i : J.info) -> J.Id.to_string i.id)
          (ok "jobs"
             (J.jobs conn ~finished:(which, fst span, snd span) ~limit:10))
      in
      let named = List.map J.Id.to_string in
      Alcotest.(check (list string))
        "the minute's success" (named [ ok_early ]) (ids J.Succeeded first);
      Alcotest.(check (list string))
        "its failure, though the job will retry" (named [ failing ])
        (ids J.Failed first);
      Alcotest.(check (list string))
        "either, newest first"
        (named [ failing; ok_early ])
        (ids J.Either first);
      Alcotest.(check (list string))
        "a later minute's alone" (named [ ok_late ])
        (ids J.Succeeded
           (plus start Mtime.Span.(2 * min), plus start Mtime.Span.(3 * min)));
      J.Runner.stop r)

let test_a_finished_job_runs_again_as_a_copy () =
  with_table (fun target conn ->
      let now, _ = clock () in
      let kind = text ~queue:"default" "note" in
      let first = enqueue conn ~now:(now ()) ~unique:"k" kind "hello" in
      let r = runner ~now target [ J.handle kind done_ ] in
      ignore (drain r);
      (match ok "again" (J.run_again conn ~now:(now ()) first) with
      | None -> Alcotest.fail "not run again"
      | Some copy ->
          check_bool "a new job" false (J.Id.equal copy first);
          let info = find conn copy in
          Alcotest.check state "waiting" J.Available info.state;
          Alcotest.(check (option string))
            "with the payload" (find conn first).payload info.payload;
          Alcotest.check outcomes "and run" [ (copy, J.Completed) ] (drain r));
      check_bool "an unknown job is none" true
        (Option.is_none
           (ok "again"
              (J.run_again conn ~now:(now ())
                 (match J.Id.of_string "999999" with
                 | Some id -> id
                 | None -> Alcotest.fail "an id"))));
      J.Runner.stop r)

let () =
  Db_target.required ~suite:"spool";
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Db_target.eio env ~sw;
  Alcotest.run "spool"
    [
      ( "enqueueing",
        [
          Alcotest.test_case "a rolled-back enqueue leaves nothing" `Quick
            test_a_rolled_back_enqueue_leaves_nothing;
          Alcotest.test_case "a key is folded into the waiting job" `Quick
            test_a_key_is_folded_into_the_waiting_job;
          Alcotest.test_case "a bad priority is refused" `Quick
            test_a_bad_priority_is_refused;
          Alcotest.test_case "a payload is an object" `Quick
            test_a_payload_is_an_object;
          Alcotest.test_case "every statement is what the database says" `Quick
            test_every_statement_is_what_the_database_says;
        ] );
      ( "an attempt",
        [
          Alcotest.test_case "done is completed" `Quick test_done_is_completed;
          Alcotest.test_case "retry waits the backoff within its spread" `Quick
            test_retry_waits_the_backoff_within_its_spread;
          Alcotest.test_case "retry in waits what it names" `Quick
            test_retry_in_waits_what_it_names;
          Alcotest.test_case "the last attempt discards" `Quick
            test_the_last_attempt_discards;
          Alcotest.test_case "discard uses no attempt" `Quick
            test_discard_uses_no_attempt;
          Alcotest.test_case "a raise is a retry named by its constructor"
            `Quick test_a_raise_is_a_retry_named_by_its_constructor;
          Alcotest.test_case "a timeout is a failure" `Quick
            test_a_timeout_is_a_failure;
          Alcotest.test_case "a payload that no longer decodes is discarded"
            `Quick test_a_payload_that_no_longer_decodes_is_discarded;
          Alcotest.test_case "an expired job is discarded unrun" `Quick
            test_an_expired_job_is_discarded_unrun;
          Alcotest.test_case "a kind not kept is deleted on completion" `Quick
            test_a_kind_not_kept_is_deleted_on_completion;
          Alcotest.test_case "a kind nobody handles is left alone" `Quick
            test_a_kind_nobody_handles_is_left_alone;
          Alcotest.test_case "order is priority, instant, enqueueing" `Quick
            test_order_is_priority_then_instant_then_enqueueing;
          Alcotest.test_case "cancel and retry" `Quick test_cancel_and_retry;
        ] );
      ( "runners",
        [
          Alcotest.test_case "two runners complete every job once" `Slow
            test_two_runners_complete_every_job_once;
          Alcotest.test_case "a runner killed has its job run again" `Quick
            test_a_runner_killed_has_its_job_run_again;
          Alcotest.test_case "a lease taken changes nothing and stops the job"
            `Quick test_a_lease_taken_changes_nothing_and_stops_the_job;
          Alcotest.test_case "a runner cut off stops its job before the lease"
            `Quick test_a_runner_cut_off_stops_its_job_before_the_lease_ends;
          Alcotest.test_case "a notification wakes a sleeping queue" `Quick
            test_a_notification_wakes_a_sleeping_queue;
          Alcotest.test_case "jobs run without the listener" `Quick
            test_jobs_run_without_the_listener;
          Alcotest.test_case "a runner idle past the heartbeat still runs jobs"
            `Slow test_a_runner_idle_past_the_heartbeat_still_runs_jobs;
          Alcotest.test_case "stop puts an interrupted job back" `Quick
            test_stop_puts_an_interrupted_job_back;
          Alcotest.test_case "finished rows are pruned by retention" `Quick
            test_finished_rows_are_pruned_by_retention;
          Alcotest.test_case "create refuses an unmigrated database" `Quick
            test_create_refuses_an_unmigrated_database;
          Alcotest.test_case "create refuses what it cannot honour" `Quick
            test_create_refuses_what_it_cannot_honour;
          Alcotest.test_case "no payload reaches a log" `Quick
            test_no_payload_reaches_a_log;
        ] );
      ( "operating",
        [
          Alcotest.test_case "a paused queue is claimed by no runner" `Quick
            test_a_paused_queue_is_claimed_by_no_runner;
          Alcotest.test_case "a queue is listed once a runner names it" `Quick
            test_a_queue_is_listed_once_a_runner_names_it;
          Alcotest.test_case "a started runner is listed until it stops" `Quick
            test_a_started_runner_is_listed_until_it_stops;
          Alcotest.test_case "a runner is seen at each heartbeat" `Quick
            test_a_runner_is_seen_at_each_heartbeat;
          Alcotest.test_case "each attempt is counted by its second" `Quick
            test_each_attempt_is_counted_by_its_second;
          Alcotest.test_case "delete removes any job but a running one" `Quick
            test_delete_removes_any_job_but_a_running_one;
        ] );
      ( "limits",
        [
          Alcotest.test_case "a limit holds across runners" `Slow
            test_a_limit_holds_across_runners;
          Alcotest.test_case "a rate holds over its period" `Quick
            test_a_rate_holds_over_its_period;
          Alcotest.test_case "partitions are claimed in turns" `Quick
            test_partitions_are_claimed_in_turns;
          Alcotest.test_case "a limit per partition" `Quick
            test_a_limit_per_partition;
          Alcotest.test_case "a limit that cannot hold is refused" `Quick
            test_a_limit_that_cannot_hold_is_refused;
        ] );
      ( "schedules",
        [
          Alcotest.test_case "a tick is local across clock changes" `Quick
            test_a_tick_is_local_across_clock_changes;
          Alcotest.test_case "a schedule that cannot run is refused" `Quick
            test_a_schedule_that_cannot_run_is_refused;
          Alcotest.test_case "a tick is one job across runners" `Quick
            test_a_tick_is_one_job_across_runners;
          Alcotest.test_case "run now enqueues beside the ticks" `Quick
            test_run_now_enqueues_beside_the_ticks;
        ] );
      ( "unique and many",
        [
          Alcotest.test_case "a key holds for its period, whatever the state"
            `Quick test_a_key_holds_for_its_period_whatever_the_state;
          Alcotest.test_case "a period without a key holds for the kind" `Quick
            test_a_period_without_a_key_holds_for_the_kind;
          Alcotest.test_case "a held key outlives retention and keep" `Quick
            test_a_held_key_outlives_retention_and_keep;
          Alcotest.test_case "many are enqueued at once" `Quick
            test_many_are_enqueued_at_once;
        ] );
      ( "workflows",
        [
          Alcotest.test_case "a summary runs once after every row" `Quick
            test_a_summary_runs_once_after_every_row;
          Alcotest.test_case "a failed row cancels what waits on it" `Quick
            test_a_failed_row_cancels_what_waits_on_it;
          Alcotest.test_case "what a job waits for may be gone or done" `Quick
            test_what_a_job_waits_for_may_be_gone_or_done;
          Alcotest.test_case "cancelling a job cancels what waits on it" `Quick
            test_cancelling_a_job_cancels_what_waits_on_it;
          Alcotest.test_case "a workflow is its jobs and their edges" `Quick
            test_a_workflow_is_its_jobs_and_their_edges;
        ] );
      ( "an operator's screen",
        [
          Alcotest.test_case "a sensitive payload reaches no answer" `Quick
            test_a_sensitive_payload_reaches_no_answer;
          Alcotest.test_case "an id reads back as it was written" `Quick
            test_an_id_reads_back_as_it_was_written;
          Alcotest.test_case "jobs are listed newest first, a page at a time"
            `Quick test_jobs_are_listed_newest_first_a_page_at_a_time;
          Alcotest.test_case "jobs are found by when an attempt finished" `Quick
            test_jobs_are_found_by_when_an_attempt_finished;
          Alcotest.test_case "a finished job runs again as a copy" `Quick
            test_a_finished_job_runs_again_as_a_copy;
        ] );
    ]
