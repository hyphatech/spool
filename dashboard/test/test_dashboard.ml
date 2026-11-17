(* The dashboard's routes, called in-process as the page calls them, against a
   real Postgres: a case's own database, spool's tables made by its own
   migrations, and the application's pool as a resource. *)

open Spindle.Syntax
module Pg = Rowtype_postgres
module T = Spindle.Test

let migrations =
  let dir = "../../migrations" in
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".sql")
  |> List.sort String.compare
  |> List.map (fun f ->
      In_channel.with_open_bin (Filename.concat dir f) In_channel.input_all)

let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)
let check_string = Alcotest.(check string)

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i =
    i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1))
  in
  go 0

let ok what = function
  | Ok v -> v
  | Error e -> Alcotest.failf "%s: %s" what (Rowtype.error_to_string e)

(* The application's operators, who say who they are in a header as a
   session would: an admin may do anything, a viewer only look. *)
type operator = Admin | Viewer

let signed_out =
  Spindle.Refusal.Code.make "signed_out" ~status:`Unauthorized
    ~challenge:"Session" ~doc:"Sign in first."

let signed_in =
  Spindle.Dep.join ~refuses:[ signed_out ]
    (let+ who = Spindle.Header.optional "x-operator" Wiretype.string in
     match who with
     | Some "admin" -> Ok Admin
     | Some "viewer" -> Ok Viewer
     | Some _ | None -> Error (Spindle.Refusal.make signed_out "Sign in first."))

let operator =
  Spindle.Access.principal
    ~id:(function Admin -> "admin" | Viewer -> "viewer")
    signed_in

let may who (action : Spool_dashboard.action) : Spindle.Access.decision =
  match (who, action) with
  | _, View | Admin, _ -> Allow
  | Viewer, _ -> Deny "a viewer only looks"

let admin = [ ("x-operator", "admin") ]
let viewer = [ ("x-operator", "viewer") ]
let json_body = [ ("content-type", "application/json") ]

let db : Spindle_postgres.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

let routes ?stream_for () =
  Spool_dashboard.routes ?stream_for ~operator ~may ~pool:db
    ~mono_clock:(Db_target.mono ()) ()

(* A case's database with spool's tables, a connection for the case's own
   work, and the dashboard started over a pool of it. *)
let with_dashboard ?stream_for f =
  Db_target.with_postgres (fun target ->
      let conn = Db_target.connect target in
      Fun.protect
        ~finally:(fun () -> Pg.close conn)
        (fun () ->
          List.iter (Db_target.exec conn) migrations;
          Eio.Switch.run @@ fun sw ->
          match
            Spindle_postgres.Pool.create ~sw ~net:(Db_target.net ())
              ~mono_clock:(Db_target.mono ()) ~size:4 target
          with
          | Error e -> Alcotest.failf "pool: %s" (Rowtype.error_to_string e)
          | Ok pool ->
              let app =
                T.app
                  ~resources:[ Spindle.Dep.resource db pool ]
                  ~mono_clock:(Db_target.mono ()) (routes ?stream_for ())
              in
              Fun.protect
                ~finally:(fun () -> Spindle_postgres.Pool.close pool)
                (fun () -> f target conn app)))

let one mem ty =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem mem ty ~enc:Fun.id
  |> Wiretype.Object.finish

let note ?queue name = Spool.Kind.make ?queue name (one "note" Wiretype.string)
let secret = "4111 1111 1111 1111"
let card = Spool.Kind.make ~sensitive:true "card" (one "card" Wiretype.string)
let now () = Ptime.truncate ~frac_s:3 (Ptime_clock.now ())

let enqueue conn kind arg =
  match Spool.enqueue conn ~now:(now ()) kind arg with
  | Ok id -> id
  | Error (#Rowtype.error as e) ->
      Alcotest.failf "enqueue: %s" (Rowtype.error_to_string e)
  | Error (`Unencodable _) -> Alcotest.fail "enqueue: unencodable"
  | Error (`Bad_priority _) -> Alcotest.fail "enqueue: priority"

let find conn id =
  match ok "find" (Spool.find conn id) with
  | Some info -> info
  | None -> Alcotest.fail "no such job"

let state_name : Spool.state -> string = function
  | Available -> "available"
  | Blocked -> "blocked"
  | Running -> "running"
  | Completed -> "completed"
  | Discarded -> "discarded"
  | Cancelled -> "cancelled"

let check_state what expected (info : Spool.info) =
  check_string what (state_name expected) (state_name info.state)

let call ?(headers = admin) ?body app meth target =
  let headers =
    match body with None -> headers | Some _ -> headers @ json_body
  in
  T.call ~now:(now ()) ~headers ?body app meth target

let ids list =
  "{\"ids\":["
  ^ String.concat ","
      (List.map (fun id -> "\"" ^ Spool.Id.to_string id ^ "\"") list)
  ^ "]}"

(* The live stream read until every part has come once, each part's data by
   its name. *)
let live ?(headers = admin) app =
  let seen = ref [] in
  let parts =
    [ "allowed"; "counts"; "queues"; "runners"; "schedules"; "chart" ]
  in
  let answer =
    T.events ~now:(now ()) ~headers app "/spool/api/live" (fun e ->
        seen := (e.name, e.data) :: !seen;
        if List.for_all (fun p -> List.mem_assoc p !seen) parts then `Stop
        else `Continue)
  in
  (answer, !seen)

(* ------------------------------------------------------------------ *)
(* The guard *)

(* Every route the dashboard has, by method and pattern, with a request for
   it: a route added without a line here fails the case below. *)
let every_route =
  [
    (`GET, "/spool", "/spool", None);
    (`GET, "/spool/assets/{file*}", "/spool/assets/index.js", None);
    (`GET, "/spool/api/live", "/spool/api/live", None);
    (`GET, "/spool/api/jobs", "/spool/api/jobs", None);
    (`GET, "/spool/api/jobs/{id}", "/spool/api/jobs/1", None);
    ( `POST,
      "/spool/api/jobs/cancel",
      "/spool/api/jobs/cancel",
      Some {|{"ids":["1"]}|} );
    ( `POST,
      "/spool/api/jobs/retry",
      "/spool/api/jobs/retry",
      Some {|{"ids":["1"]}|} );
    ( `POST,
      "/spool/api/jobs/delete",
      "/spool/api/jobs/delete",
      Some {|{"ids":["1"]}|} );
    ( `POST,
      "/spool/api/queues/{queue}/pause",
      "/spool/api/queues/default/pause",
      None );
    ( `POST,
      "/spool/api/queues/{queue}/resume",
      "/spool/api/queues/default/resume",
      None );
    ( `POST,
      "/spool/api/queues/{queue}/limits",
      "/spool/api/queues/default/limits",
      Some {|{"running":1,"rate":null,"per_partition":false}|} );
    ( `POST,
      "/spool/api/schedules/{schedule}/run",
      "/spool/api/schedules/nightly/run",
      None );
    (`POST, "/spool/api/jobs/{id}/again", "/spool/api/jobs/1/again", None);
  ]

let status (r : T.response) = Spindle_http.Status.to_int r.status

(* Nothing a refused request asked for was done: the job still waits, no
   queue is paused or limited, and nothing more was enqueued. *)
let nothing_done conn id =
  check_state "still waiting" Available (find conn id);
  List.iter
    (fun (q : Spool.Queue.t) ->
      check_bool (q.name ^ " not paused") false q.paused;
      check_bool (q.name ^ " not limited") true (Option.is_none q.running))
    (ok "queues" (Spool.Queue.list conn));
  check_int "nothing more enqueued" 1
    (List.length (ok "jobs" (Spool.jobs conn ~limit:10)))

let meth_name m = Spindle_http.Meth.to_string m

let test_every_route_is_asked () =
  match Spindle.App.make (routes ()) with
  | Error e -> Alcotest.fail e
  | Ok app ->
      let routed =
        List.map
          (fun (r : Spindle.Route.info) -> meth_name r.meth ^ " " ^ r.pattern)
          (Spindle.App.routes app)
      and asked =
        List.map
          (fun (m, pattern, _, _) -> meth_name m ^ " " ^ pattern)
          every_route
      in
      Alcotest.(check (list string))
        "every route, asked below"
        (List.sort String.compare routed)
        (List.sort String.compare asked)

let test_no_route_answers_a_stranger () =
  with_dashboard (fun _ conn app ->
      let id = enqueue conn card secret in
      List.iter
        (fun (meth, pattern, target, body) ->
          let what = meth_name meth ^ " " ^ pattern in
          match (meth, pattern) with
          | `GET, "/spool/api/live" -> (
              match fst (live ~headers:[] app) with
              | Ok () -> Alcotest.failf "%s: streamed to a stranger" what
              | Error r -> check_int what 401 (status r))
          | _ ->
              let r = call ~headers:[] ?body app meth target in
              check_int what 401 (status r);
              check_bool
                (what ^ ": the refusal alone")
                true
                (contains r.body "signed_out"))
        every_route;
      nothing_done conn id)

let test_a_viewer_only_looks () =
  with_dashboard (fun _ conn app ->
      let id = enqueue conn card secret in
      List.iter
        (fun (meth, pattern, target, body) ->
          let what = meth_name meth ^ " " ^ pattern in
          match (meth, pattern) with
          | `GET, "/spool/api/live" -> (
              match fst (live ~headers:viewer app) with
              | Ok () -> ()
              | Error r -> Alcotest.failf "%s: %d" what (status r))
          | `GET, _ ->
              let r = call ~headers:viewer app meth target in
              check_bool (what ^ ": let in") true
                (status r <> 401 && status r <> 403)
          | _ ->
              let r = call ~headers:viewer ?body app meth target in
              check_int what 403 (status r);
              check_bool
                (what ^ ": the refusal alone")
                true
                (contains r.body "forbidden"))
        every_route;
      nothing_done conn id)

let test_no_route_is_anyones () =
  Alcotest.(check (list string))
    "no route but through the operator's check" []
    (Spindle.Access.unguarded (routes ()))

let test_the_page_is_told_what_its_viewer_may_do () =
  with_dashboard (fun _ _ app ->
      let allowed headers =
        match List.assoc_opt "allowed" (snd (live ~headers app)) with
        | Some data -> data
        | None -> Alcotest.fail "no allowed"
      in
      check_string "a viewer views" {|["view"]|} (allowed viewer);
      let all = allowed admin in
      List.iter
        (fun action ->
          check_bool ("an admin may " ^ action) true
            (contains all ("\"" ^ action ^ "\"")))
        [
          "view";
          "cancel";
          "retry";
          "delete";
          "run_again";
          "pause";
          "resume";
          "set_limits";
          "run_schedule";
        ])

(* A stream ends by itself, so the viewer is asked for again when the page
   opens the next. *)
let test_a_stream_ends_after_its_time () =
  let stream_for = Mtime.Span.(300 * ms) in
  with_dashboard ~stream_for (fun _ _ app ->
      let clock = Db_target.mono () in
      let start = Eio.Time.Mono.now clock in
      (match
         T.events ~now:(now ()) ~headers:admin app "/spool/api/live" (fun _ ->
             `Continue)
       with
      | Ok () -> ()
      | Error r -> Alcotest.failf "live: %d" (status r));
      (* Its time, and the second of the reader it shares the stream with. *)
      let took = Mtime.span start (Eio.Time.Mono.now clock) in
      check_bool "ended in its time" true
        (Mtime.Span.is_shorter took ~than:Mtime.Span.(2 * s)))

let test_the_page_lets_an_operator_in () =
  with_dashboard (fun _ _ app ->
      let r = call app `GET "/spool" in
      check_int "the page" 200 (status r);
      check_bool "is the page" true (contains r.body "<html");
      let r = call app `GET "/spool/api/jobs" in
      check_int "the jobs" 200 (status r))

(* ------------------------------------------------------------------ *)
(* A sensitive kind *)

let test_a_sensitive_payload_reaches_no_answer () =
  with_dashboard (fun _ conn app ->
      let hidden = enqueue conn card secret in
      let plain = enqueue conn (note "note") "hello" in
      let bodies = ref [] in
      let keep (r : T.response) = bodies := r.body :: !bodies in
      List.iter
        (fun (meth, _, target, body) ->
          match target with
          | "/spool/api/live" -> ()
          | _ -> keep (call ?body app meth target))
        every_route;
      List.iter
        (fun target -> keep (call app `GET target))
        [
          "/spool/api/jobs";
          "/spool/api/jobs?kind=card";
          "/spool/api/jobs/" ^ Spool.Id.to_string hidden;
          "/spool/api/jobs/" ^ Spool.Id.to_string plain;
        ];
      let answer, events = live app in
      (match answer with
      | Ok () -> ()
      | Error r ->
          Alcotest.failf "live: %d" (Spindle_http.Status.to_int r.status));
      List.iter (fun (_, data) -> bodies := data :: !bodies) events;
      List.iter
        (fun (meth, target) ->
          keep (call ~body:(ids [ hidden ]) app meth target))
        [
          (`POST, "/spool/api/jobs/cancel");
          (`POST, "/spool/api/jobs/retry");
          (`POST, "/spool/api/jobs/delete");
        ];
      check_bool "the plain one is shown" true
        (List.exists (fun b -> contains b "hello") !bodies);
      List.iter
        (fun body ->
          check_bool "no answer holds the secret" false (contains body "4111"))
        !bodies)

(* ------------------------------------------------------------------ *)
(* Reading *)

(* A page of jobs, read for their ids alone. *)
let listed_ids =
  Wiretype.list
    (Wiretype.Object.map Fun.id
    |> Wiretype.Object.mem "id" Wiretype.string ~enc:Fun.id
    |> Wiretype.Object.finish)

let test_jobs_are_paged_newest_first () =
  with_dashboard (fun _ conn app ->
      let kind = note "note" in
      let all = List.init 5 (fun i -> enqueue conn kind (string_of_int i)) in
      let _other = enqueue conn (note ~queue:"other" "other") "x" in
      let listed target =
        let r = call app `GET target in
        check_int target 200 (Spindle_http.Status.to_int r.status);
        match Wiretype.decode listed_ids r.body with
        | Ok ids -> ids
        | Error _ -> Alcotest.failf "%s: %s" target r.body
      in
      let newest = List.rev_map Spool.Id.to_string all in
      let first = listed "/spool/api/jobs?kind=note&limit=2" in
      Alcotest.(check (list string))
        "the newest two"
        (List.filteri (fun i _ -> i < 2) newest)
        first;
      let last = List.nth_opt first 1 |> Option.value ~default:"" in
      let next = listed ("/spool/api/jobs?kind=note&limit=2&before=" ^ last) in
      Alcotest.(check (list string))
        "the two below them"
        (List.filteri (fun i _ -> i >= 2 && i < 4) newest)
        next;
      check_int "by queue" 1
        (List.length (listed "/spool/api/jobs?queue=other"));
      check_int "by state" 6
        (List.length (listed "/spool/api/jobs?state=available"));
      check_int "none completed" 0
        (List.length (listed "/spool/api/jobs?state=completed"));
      let r = call app `GET "/spool/api/jobs?before=x" in
      check_int "an id that is none" 400 (Spindle_http.Status.to_int r.status))

let test_a_job_is_shown_with_its_workflow () =
  with_dashboard (fun _ conn app ->
      let kind = note "row" in
      let a = enqueue conn kind "a" in
      let summary =
        match
          Spool.enqueue_after conn ~now:(now ()) ~waits_for:[ a ]
            (note "summary") "s"
        with
        | Ok id -> id
        | Error _ -> Alcotest.fail "enqueue_after"
      in
      let r = call app `GET ("/spool/api/jobs/" ^ Spool.Id.to_string summary) in
      check_int "found" 200 (Spindle_http.Status.to_int r.status);
      check_bool "its payload" true (contains r.body {|"note":"s"|});
      check_bool "blocked" true (contains r.body {|"state":"blocked"|});
      check_bool "waits for the row" true
        (contains r.body
           ({|"job":"|} ^ Spool.Id.to_string summary ^ {|","waits_for":"|}
          ^ Spool.Id.to_string a ^ {|"|}));
      let r = call app `GET "/spool/api/jobs/999999" in
      check_int "no such job" 404 (Spindle_http.Status.to_int r.status))

let test_live_sends_every_part () =
  with_dashboard (fun _ conn app ->
      let _ = enqueue conn (note "note") "a"
      and _ = enqueue conn (note "note") "b" in
      let answer, events = live app in
      (match answer with
      | Ok () -> ()
      | Error r ->
          Alcotest.failf "live: %d" (Spindle_http.Status.to_int r.status));
      match List.assoc_opt "counts" events with
      | None -> Alcotest.fail "no counts"
      | Some data ->
          check_bool "two waiting in default" true
            (contains data {|"queue":"default","available":2|}))

(* The chart names each kind attempted with its queue, so the page offers a
   queue's kinds alone once a queue is chosen. *)
let test_kinds_come_with_their_queue () =
  with_dashboard (fun target conn app ->
      let receipt = note ~queue:"mail" "receipt"
      and report = note ~queue:"reports" "report" in
      let _ = enqueue conn receipt "r" and _ = enqueue conn report "p" in
      let runner =
        match
          Spool.Runner.create ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
            ~mono_clock:(Db_target.mono ()) ~now
            ~queues:[ ("mail", 1); ("reports", 1) ]
            [
              Spool.handle receipt (fun _ _ -> Ok ());
              Spool.handle report (fun _ _ -> Ok ());
            ]
            target
        with
        | Ok r -> r
        | Error e ->
            Alcotest.failf "runner: %s" (Spool.Runner.refused_to_string e)
      in
      (match Spool.Runner.drain runner with
      | Ok _ -> ()
      | Error e -> Alcotest.fail e);
      Spool.Runner.stop runner;
      match List.assoc_opt "chart" (snd (live app)) with
      | None -> Alcotest.fail "no chart"
      | Some data ->
          check_bool "receipt in mail" true
            (contains data {|{"queue":"mail","kind":"receipt"}|});
          check_bool "report in reports" true
            (contains data {|{"queue":"reports","kind":"report"}|}))

(* ------------------------------------------------------------------ *)
(* Acting *)

let test_actions_are_spools () =
  with_dashboard (fun _ conn app ->
      let kind = note "note" in
      let a = enqueue conn kind "a" and b = enqueue conn kind "b" in
      let r = call ~body:(ids [ a; b ]) app `POST "/spool/api/jobs/cancel" in
      check_int "cancelled" 200 (Spindle_http.Status.to_int r.status);
      check_state "a cancelled" Cancelled (find conn a);
      check_state "b cancelled" Cancelled (find conn b);
      let r = call ~body:(ids [ a ]) app `POST "/spool/api/jobs/cancel" in
      check_bool "a second cancel skips it" true
        (contains r.body ({|"skipped":["|} ^ Spool.Id.to_string a));
      let _ = call ~body:(ids [ a ]) app `POST "/spool/api/jobs/retry" in
      check_state "a retried" Available (find conn a);
      let _ = call ~body:(ids [ b ]) app `POST "/spool/api/jobs/delete" in
      check_bool "b deleted" true
        (Option.is_none (ok "find" (Spool.find conn b)));
      let r = call ~body:{|{"ids":[]}|} app `POST "/spool/api/jobs/delete" in
      check_int "an empty selection" 400 (Spindle_http.Status.to_int r.status);
      let paused () =
        List.exists
          (fun (q : Spool.Queue.t) -> String.equal q.name "mail" && q.paused)
          (ok "queues" (Spool.Queue.list conn))
      in
      let _ = call app `POST "/spool/api/queues/mail/pause" in
      check_bool "paused" true (paused ());
      let _ = call app `POST "/spool/api/queues/mail/resume" in
      check_bool "resumed" false (paused ()))

(* The lines logged while [f] runs, by source, as they are written. *)
let logged f =
  let lines = ref [] in
  let previous = Logs.reporter () and level = Logs.level () in
  let report src _level ~over k msgf =
    msgf (fun ?header:_ ?tags:_ fmt ->
        Format.kasprintf
          (fun line ->
            lines := (Logs.Src.name src, line) :: !lines;
            over ();
            k ())
          fmt)
  in
  Logs.set_reporter { Logs.report };
  Logs.set_level (Some Logs.Info);
  Fun.protect
    ~finally:(fun () ->
      Logs.set_reporter previous;
      Logs.set_level level)
    f;
  List.rev !lines

let test_an_action_is_logged () =
  with_dashboard (fun _ conn app ->
      let kind = note "note" in
      let a = enqueue conn kind "a" and b = enqueue conn kind "b" in
      let lines =
        logged (fun () ->
            let r =
              call ~body:(ids [ a; b ]) app `POST "/spool/api/jobs/cancel"
            in
            check_int "cancelled" 200 (status r))
      in
      match
        List.filter (fun (src, _) -> String.equal src "spool-dashboard") lines
      with
      | [ (_, line) ] ->
          check_bool "says what" true (contains line "cancel");
          List.iter
            (fun id ->
              check_bool "names each job" true
                (contains line (Spool.Id.to_string id)))
            [ a; b ];
          check_bool "and no payload" false (contains line "\"note\"")
      | lines -> Alcotest.failf "%d lines, not one" (List.length lines))

let test_a_queue_is_limited () =
  with_dashboard (fun _ conn app ->
      let limits body =
        call ~body app `POST "/spool/api/queues/partner/limits"
      in
      let r =
        limits
          {|{"running":2,"rate":{"attempts":60,"per_ms":60000},"per_partition":true}|}
      in
      check_int "set" 204 (status r);
      (match
         List.find_opt
           (fun (q : Spool.Queue.t) -> String.equal q.name "partner")
           (ok "queues" (Spool.Queue.list conn))
       with
      | None -> Alcotest.fail "no partner queue"
      | Some q ->
          check_bool "two at once" true
            (Option.equal Int.equal q.running (Some 2));
          check_bool "per partition" true q.per_partition;
          check_bool "sixty a minute" true
            (match q.rate with
            | Some r -> r.attempts = 60 && Mtime.Span.equal r.per Mtime.Span.min
            | None -> false));
      let r = limits {|{"running":0,"rate":null,"per_partition":false}|} in
      check_int "no slot" 400 (status r);
      check_bool "says why" true (contains r.body "slot");
      let r =
        limits
          {|{"running":null,"rate":{"attempts":1,"per_ms":-1},"per_partition":false}|}
      in
      check_int "a period before nothing" 400 (status r);
      let r = limits {|{"running":null,"rate":null,"per_partition":false}|} in
      check_int "lifted" 204 (status r))

let test_a_schedule_runs_now () =
  with_dashboard (fun target conn app ->
      let nightly =
        Spool.Schedule.make ~name:"nightly" ~cron:"0 2 * * *" ~zone:"UTC"
          (note "report") "r"
      in
      let runner =
        match
          Spool.Runner.create ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
            ~mono_clock:(Db_target.mono ()) ~now ~schedules:[ nightly ]
            ~queues:[ ("other", 1) ]
            [] target
        with
        | Ok r -> r
        | Error e ->
            Alcotest.failf "runner: %s" (Spool.Runner.refused_to_string e)
      in
      (match Spool.Runner.drain runner with
      | Ok _ -> ()
      | Error e -> Alcotest.fail e);
      Spool.Runner.stop runner;
      let r = call app `POST "/spool/api/schedules/nightly/run" in
      check_int "run" 200 (Spindle_http.Status.to_int r.status);
      check_int "one report waits" 1
        (List.length (ok "jobs" (Spool.jobs conn ~kind:"report" ~limit:10)));
      let r = call app `POST "/spool/api/schedules/weekly/run" in
      check_int "no such schedule" 404 (Spindle_http.Status.to_int r.status))

let test_run_again_enqueues_a_copy () =
  with_dashboard (fun _ conn app ->
      let id = enqueue conn card secret in
      let r =
        call app `POST ("/spool/api/jobs/" ^ Spool.Id.to_string id ^ "/again")
      in
      check_int "run again" 200 (Spindle_http.Status.to_int r.status);
      check_int "two of the kind wait" 2
        (List.length (ok "jobs" (Spool.jobs conn ~kind:"card" ~limit:10)));
      let r = call app `POST "/spool/api/jobs/999999/again" in
      check_int "no such job" 404 (Spindle_http.Status.to_int r.status))

let () =
  Db_target.required ~suite:"spool-dashboard";
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Db_target.eio env ~sw;
  Alcotest.run "spool-dashboard"
    [
      ( "access",
        [
          Alcotest.test_case "every route is asked" `Quick
            test_every_route_is_asked;
          Alcotest.test_case "no route answers a stranger" `Quick
            test_no_route_answers_a_stranger;
          Alcotest.test_case "a viewer only looks" `Quick
            test_a_viewer_only_looks;
          Alcotest.test_case "no route is anyone's" `Quick
            test_no_route_is_anyones;
          Alcotest.test_case "the page is told what its viewer may do" `Quick
            test_the_page_is_told_what_its_viewer_may_do;
          Alcotest.test_case "a stream ends after its time" `Quick
            test_a_stream_ends_after_its_time;
          Alcotest.test_case "the page lets an operator in" `Quick
            test_the_page_lets_an_operator_in;
        ] );
      ( "a sensitive kind",
        [
          Alcotest.test_case "its payload reaches no answer" `Quick
            test_a_sensitive_payload_reaches_no_answer;
        ] );
      ( "reading",
        [
          Alcotest.test_case "jobs are paged newest first" `Quick
            test_jobs_are_paged_newest_first;
          Alcotest.test_case "a job is shown with its workflow" `Quick
            test_a_job_is_shown_with_its_workflow;
          Alcotest.test_case "live sends every part" `Quick
            test_live_sends_every_part;
          Alcotest.test_case "kinds come with their queue" `Quick
            test_kinds_come_with_their_queue;
        ] );
      ( "acting",
        [
          Alcotest.test_case "actions are spool's" `Quick
            test_actions_are_spools;
          Alcotest.test_case "an action is logged" `Quick
            test_an_action_is_logged;
          Alcotest.test_case "a queue is limited" `Quick test_a_queue_is_limited;
          Alcotest.test_case "a schedule runs now" `Quick
            test_a_schedule_runs_now;
          Alcotest.test_case "a job runs again as a copy" `Quick
            test_run_again_enqueues_a_copy;
        ] );
    ]
