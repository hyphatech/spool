open Spindle.Syntax
module Path = Spindle.Path

let not_found = Spindle.Refusal.Code.not_found

(* What Vite names by a hash of its bytes is kept a year, as
   [Spindle.Cache.forever] keeps it; the page is asked for each time, so a
   new build is a new page naming new files. *)
let forever = ("cache-control", "public, max-age=31536000, immutable")
let no_cache = ("cache-control", "no-cache")

let types =
  [
    (".js", "text/javascript; charset=utf-8");
    (".css", "text/css; charset=utf-8");
    (".html", "text/html; charset=utf-8");
    (".svg", "image/svg+xml");
    (".woff2", "font/woff2");
    (".png", "image/png");
  ]

let content_type file =
  match
    List.find_opt (fun (ext, _) -> Filename.check_suffix file ext) types
  with
  | Some (_, t) -> t
  | None -> "application/octet-stream"

(* The page is served at [at] itself, never under it, so a URL it names
   relative to itself resolves beside it: Vite's [./assets/] is made
   [<last segment>/assets/], which a proxy's prefix leaves right. *)
let page ~at =
  let html = Option.value (Bundle.read "index.html") ~default:"" in
  let segment =
    match List.rev (String.split_on_char '/' (Path.pattern at)) with
    | last :: _ when not (String.equal last "") -> last ^ "/"
    | _ :: _ | [] -> "./"
  in
  let b = Buffer.create (String.length html) in
  let from = "\"./assets/" in
  let n = String.length from in
  let rec copy i =
    if i < String.length html then
      if i + n <= String.length html && String.equal (String.sub html i n) from
      then begin
        Buffer.add_string b ("\"" ^ segment ^ "assets/");
        copy (i + n)
      end
      else begin
        Buffer.add_char b html.[i];
        copy (i + 1)
      end
  in
  copy 0;
  Buffer.contents b

let refusal e = Spindle_postgres.refusal e

type action = Wire.action =
  | View
  | Cancel
  | Retry
  | Delete
  | Run_again
  | Pause
  | Resume
  | Set_limits
  | Run_schedule

module Log = Live.Log

(* A stream is one request, asked once: ending it this often has the page
   open the next, which asks again, so access taken away stops a viewer
   within it. *)
let stream_for_default = Mtime.Span.min

let routes ?(at = Path.(s "spool")) ?(stream_for = stream_for_default) ~operator
    ~may ~pool ~mono_clock () =
  let live = Live.create ~mono_clock ~stream_for in
  let html = page ~at in
  let file = Path.rest "file" in
  let id = Path.param "id" Wire.id_json in
  let queue = Path.string "queue" in
  let schedule = Path.string "schedule" in
  let api = Path.(at / s "api") in
  let policy =
    Spindle.Access.policy "spool-dashboard" operator ~action:Wire.action_name
      (fun who action () -> may who action)
  in
  let allowed action = Spindle.Access.require policy action in
  let codes action = Spindle.Dep.codes (allowed action) in
  let ids list = String.concat ", " (List.map Spool.Id.to_string list) in
  (* A selection's jobs in one transaction, each as spool answered for it:
     changed, or left as it was. *)
  let act ~summary action each =
    let name = Wire.action_name action in
    Spindle.post ~summary ~refuses:(codes action)
      Path.(api / s "jobs" / s name)
      (Spindle.Returns.json Wire.outcome_json)
      (let+ () = allowed action
       and+ pool = pool
       and+ now = Spindle.now
       and+ (selection : Wire.selection) = Spindle.json Wire.selection_json in
       Spindle_postgres.Pool.transaction pool (fun conn ->
           List.fold_left
             (fun acc job ->
               let* applied, skipped = acc in
               let* changed = each conn ~now job in
               Ok
                 (if changed then (job :: applied, skipped)
                  else (applied, job :: skipped)))
             (Ok ([], []))
             selection.ids)
       |> Result.map (fun (applied, skipped) : Wire.outcome ->
           let applied = List.rev applied and skipped = List.rev skipped in
           Log.info (fun m ->
               m "%s: jobs %s; left as they were: %s" name (ids applied)
                 (ids skipped));
           { applied; skipped })
       |> Result.map_error refusal)
  in
  let on_queue ~summary action f =
    let name = Wire.action_name action in
    Spindle.post ~summary ~refuses:(codes action)
      Path.(api / s "queues" / queue / s name)
      (Spindle.Returns.empty ())
      (let+ () = allowed action
       and+ pool = pool
       and+ now = Spindle.now
       and+ queue = Spindle.param queue in
       Spindle_postgres.Pool.use pool (fun conn -> f conn ~now queue)
       |> Result.map (fun () -> Log.info (fun m -> m "%s: queue %s" name queue))
       |> Result.map_error refusal)
  in
  [
    Spindle.get ~summary:"The dashboard's page" ~refuses:(codes View) at
      Spindle.Returns.response
      (let+ () = allowed View in
       Ok (Spindle.Response.html ~headers:[ no_cache ] html));
    Spindle.get ~summary:"The page's files" ~refuses:(not_found :: codes View)
      Path.(at / s "assets" / file)
      Spindle.Returns.response
      (let+ () = allowed View and+ parts = Spindle.param file in
       let name = String.concat "/" ("assets" :: parts) in
       match Bundle.read name with
       | Some body ->
           Ok
             (Spindle.Response.make ~headers:[ forever ]
                ~content_type:(content_type name) body)
       | None -> Error Spindle.Refusal.not_found);
    Spindle.get ~summary:"The queue's state, live" ~refuses:(codes View)
      Path.(api / s "live")
      (Spindle.Returns.events Live.declared)
      (let+ () = allowed View
       and+ who = Spindle.Access.caller operator
       and+ pool = pool
       and+ now = Spindle.now
       and+ gone = Spindle.client_gone in
       let may_do action =
         match may who action with
         | Spindle.Access.Allow -> true
         | Deny _ -> false
       in
       Ok
         (Live.watch live ~pool ~now ~gone
            ~allowed:(List.filter may_do Wire.actions)));
    Spindle.get ~summary:"Jobs, newest first" ~refuses:(codes View)
      Path.(api / s "jobs")
      (Spindle.Returns.json (Wiretype.list Wire.job_json))
      (let+ () = allowed View
       and+ pool = pool
       and+ state = Spindle.Query.optional "state" Wire.state_json
       and+ queue = Spindle.Query.optional "queue" Wiretype.string
       and+ kind = Spindle.Query.optional "kind" Wiretype.string
       and+ before = Spindle.Query.optional "before" Wire.id_json
       and+ minute = Spindle.Query.optional "minute" Wiretype.instant
       and+ ended = Spindle.Query.default "ended" Wire.ended_json Wire.Either
       and+ limit =
         Spindle.Query.default "limit"
           (Wiretype.int_bounded ~min:1 ~max:200 ())
           50
       in
       Spindle_postgres.Pool.use pool (fun conn ->
           (* A chart's minute: the jobs with an attempt that finished in
              it, from its start to the next minute's. *)
           let span =
             Option.map
               (fun m ->
                 ( m,
                   Option.value ~default:m
                     (Ptime.add_span m (Ptime.Span.of_int_s 60)) ))
               minute
           in
           let finished =
             Option.map (fun (m, next) -> (Wire.finished ended, m, next)) span
           in
           let* jobs =
             Spool.jobs
               ?state:(Option.map Wire.of_state state)
               ?queue ?kind ?finished ?before conn ~limit
           in
           Ok
             (List.map
                (Wire.job
                   ?minute:(Option.map (fun (m, next) -> (m, next, ended)) span))
                jobs))
       |> Result.map_error refusal);
    Spindle.get ~summary:"A job, its attempts and its workflow"
      ~refuses:(not_found :: codes View)
      Path.(api / s "jobs" / id)
      (Spindle.Returns.json Wire.detail_json)
      (let+ () = allowed View and+ pool = pool and+ id = Spindle.param id in
       match
         Spindle_postgres.Pool.use pool (fun conn ->
             let* found = Spool.find conn id in
             match found with
             | None -> Ok None
             | Some info ->
                 let* workflow = Spool.workflow conn id in
                 Ok (Some (Wire.detail info workflow)))
       with
       | Ok (Some detail) -> Ok detail
       | Ok None -> Error Spindle.Refusal.not_found
       | Error e -> Error (refusal e));
    act ~summary:"Cancel jobs" Cancel (fun conn ~now job ->
        Spool.cancel conn ~now job);
    act ~summary:"Retry jobs" Retry (fun conn ~now job ->
        let* retried = Spool.retry conn ~now job in
        Ok (Option.is_some retried));
    act ~summary:"Delete jobs" Delete (fun conn ~now job ->
        Spool.delete conn ~now job);
    on_queue ~summary:"Pause a queue" Pause Spool.Queue.pause;
    on_queue ~summary:"Resume a queue" Resume Spool.Queue.resume;
    Spindle.post ~summary:"Set a queue's limits"
      ~refuses:(Spindle.Refusal.Code.invalid :: codes Set_limits)
      Path.(api / s "queues" / queue / s "limits")
      (Spindle.Returns.empty ())
      (let+ () = allowed Set_limits
       and+ pool = pool
       and+ now = Spindle.now
       and+ queue = Spindle.param queue
       and+ (limits : Wire.limits) = Spindle.json Wire.limits_json in
       match
         Spindle_postgres.Pool.use pool (fun conn ->
             Spool.Queue.set_limits conn ~now ~running:limits.running
               ~rate:(Option.map Wire.of_rate limits.rate)
               ~per_partition:limits.per_partition queue)
       with
       | Ok () ->
           Log.info (fun m -> m "set_limits: queue %s" queue);
           Ok ()
       | Error (`Bad_limit why) ->
           Error (Spindle.Dep.problem ~at:"" ~code:"bad_limit" why)
       | Error (#Spindle_postgres.error as e) -> Error (refusal e));
    Spindle.post ~summary:"Run a schedule now"
      ~refuses:(not_found :: codes Run_schedule)
      Path.(api / s "schedules" / schedule / s "run")
      (Spindle.Returns.json Wire.enqueued_json)
      (let+ () = allowed Run_schedule
       and+ pool = pool
       and+ now = Spindle.now
       and+ name = Spindle.param schedule in
       match
         Spindle_postgres.Pool.use pool (fun conn ->
             Spool.Schedule.run_now conn ~now name)
       with
       | Ok (Some id) ->
           Log.info (fun m ->
               m "run_schedule: %s, job %s" name (Spool.Id.to_string id));
           Ok ({ id } : Wire.enqueued)
       | Ok None -> Error Spindle.Refusal.not_found
       | Error e -> Error (refusal e));
    Spindle.post ~summary:"Run a job again, as a copy"
      ~refuses:(not_found :: codes Run_again)
      Path.(api / s "jobs" / id / s "again")
      (Spindle.Returns.json Wire.enqueued_json)
      (let+ () = allowed Run_again
       and+ pool = pool
       and+ now = Spindle.now
       and+ id = Spindle.param id in
       match
         Spindle_postgres.Pool.use pool (fun conn ->
             Spool.run_again conn ~now id)
       with
       | Ok (Some copy) ->
           Log.info (fun m ->
               m "run_again: job %s, as job %s" (Spool.Id.to_string id)
                 (Spool.Id.to_string copy));
           Ok ({ id = copy } : Wire.enqueued)
       | Ok None -> Error Spindle.Refusal.not_found
       | Error e -> Error (refusal e));
  ]
