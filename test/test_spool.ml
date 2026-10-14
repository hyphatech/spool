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

let enqueue ?at ?after ?priority ?unique ?expires_at conn ~now kind arg =
  match
    Pg.Transaction.within conn (fun c ->
        J.enqueue ?at ?after ?priority ?unique ?expires_at c ~now kind arg)
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

let runner ?(queues = [ ("default", 4) ]) ?poll ?lease ?retain_completed ~now
    target handlers =
  match
    J.Runner.create ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
      ~mono_clock:(Db_target.mono ()) ~now ?poll ?lease ?retain_completed
      ~queues handlers target
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
    ]
