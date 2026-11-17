type action =
  | View
  | Cancel
  | Retry
  | Delete
  | Run_again
  | Pause
  | Resume
  | Set_limits
  | Run_schedule
[@@deriving wiretype]

let actions =
  [
    View;
    Cancel;
    Retry;
    Delete;
    Run_again;
    Pause;
    Resume;
    Set_limits;
    Run_schedule;
  ]

let action_name = function
  | View -> "view"
  | Cancel -> "cancel"
  | Retry -> "retry"
  | Delete -> "delete"
  | Run_again -> "run_again"
  | Pause -> "pause"
  | Resume -> "resume"
  | Set_limits -> "set_limits"
  | Run_schedule -> "run_schedule"

let id_json =
  Wiretype.kind ~kind:"job_id" ~doc:"A job's id, as spool writes it."
    ~parse:(fun s ->
      match Spool.Id.of_string s with
      | Some id -> Ok id
      | None -> Error "A job's id is a number written in digits.")
    ~print:Spool.Id.to_string Wiretype.string

type state = Available | Blocked | Running | Completed | Discarded | Cancelled
[@@deriving wiretype]

let state : Spool.state -> state = function
  | Available -> Available
  | Blocked -> Blocked
  | Running -> Running
  | Completed -> Completed
  | Discarded -> Discarded
  | Cancelled -> Cancelled

let of_state : state -> Spool.state = function
  | Available -> Available
  | Blocked -> Blocked
  | Running -> Running
  | Completed -> Completed
  | Discarded -> Discarded
  | Cancelled -> Cancelled

type ended = Done | Failed | Either [@@deriving wiretype]

let finished : ended -> Spool.finished = function
  | Done -> Succeeded
  | Failed -> Failed
  | Either -> Either

type failed = { attempt : int; at : Ptime.t; reason : string }
[@@deriving wiretype]

type moment_outcome = Completed | Failed | Discarded [@@deriving wiretype]

type moment = {
  outcome : moment_outcome;
  attempt : int;
  reason : string option;
}
[@@deriving wiretype]

type job = {
  id : Spool.Id.t; [@with id_json]
  queue : string;
  kind : string;
  state : state;
  priority : int;
  attempt : int;
  max_attempts : int;
  scheduled_at : Ptime.t;
  inserted_at : Ptime.t;
  finished_at : Ptime.t option;
  last_error : string option;
  in_minute : moment option;
}
[@@deriving wiretype]

(* What one of the job's attempts came to within [from, until): the last
   such attempt, a failure as its recorded error says, a completion as its
   finish does. *)
let moment ~from ~until ~ended (i : Spool.info) =
  let within t =
    (not (Ptime.is_earlier t ~than:from)) && Ptime.is_earlier t ~than:until
  in
  (* A discarded job's last recorded failure is the one that discarded it. *)
  let last = List.length i.errors - 1 in
  let failure =
    List.fold_left
      (fun (n, found) (f : Spool.failed) ->
        let discarded =
          match i.state with
          | Discarded -> n = last
          | Available | Blocked | Running | Completed | Cancelled -> false
        in
        ( n + 1,
          if within f.at then
            Some
              {
                outcome = (if discarded then Discarded else Failed);
                attempt = f.attempt;
                reason = Some f.reason;
              }
          else found ))
      (0, None) i.errors
    |> snd
  in
  let completed =
    match (i.state, i.finished_at) with
    | Completed, Some at -> within at
    | (Available | Blocked | Running | Completed | Discarded | Cancelled), _ ->
        false
  in
  let completion =
    if completed then
      Some { outcome = Completed; attempt = i.attempt; reason = None }
    else None
  in
  (* The list asked for failures, or for completions, says that one; asked
     for either, the job's completion, which came after its failures. *)
  match (ended : ended) with
  | Failed -> failure
  | Done -> completion
  | Either -> ( match completion with Some _ -> completion | None -> failure)

let job ?minute (i : Spool.info) =
  {
    id = i.id;
    queue = i.queue;
    kind = i.kind;
    state = state i.state;
    priority = i.priority;
    attempt = i.attempt;
    max_attempts = i.max_attempts;
    scheduled_at = i.scheduled_at;
    inserted_at = i.inserted_at;
    finished_at = i.finished_at;
    last_error =
      List.fold_left (fun _ (f : Spool.failed) -> Some f.reason) None i.errors;
    in_minute =
      Option.bind minute (fun (from, until, ended) ->
          moment ~from ~until ~ended i);
  }

type edge = {
  job : Spool.Id.t; [@with id_json]
  waits_for : Spool.Id.t; [@with id_json]
}
[@@deriving wiretype]

type payload = Shown of { value : Wiretype.Value.t } | Hidden
[@@deriving wiretype]

type detail = {
  job : job;
  errors : failed list;
  payload : payload;
  workflow : job list;
  edges : edge list;
}
[@@deriving wiretype]

let detail (i : Spool.info) (w : Spool.workflow) =
  {
    job = job i;
    errors =
      List.map
        (fun (f : Spool.failed) ->
          { attempt = f.attempt; at = f.at; reason = f.reason })
        i.errors;
    (* Spool's payload is the JSON Postgres wrote, so it reads; a payload
       that did not would be shown as the text it is. *)
    payload =
      (match i.payload with
      | None -> Hidden
      | Some text -> (
          match Wiretype.decode Wiretype.Value.json text with
          | Ok value -> Shown { value }
          | Error _ -> Shown { value = Wiretype.Value.String text }));
    workflow = List.map job w.jobs;
    edges = List.map (fun (job, waits_for) -> { job; waits_for }) w.edges;
  }

type queue_count = {
  queue : string;
  available : int;
  blocked : int;
  running : int;
}
[@@deriving wiretype]

let queue_counts rows =
  let add (c : queue_count) (st : Spool.state) n =
    match st with
    | Available -> { c with available = c.available + n }
    | Blocked -> { c with blocked = c.blocked + n }
    | Running -> { c with running = c.running + n }
    | Completed | Discarded | Cancelled -> c
  in
  let by_queue =
    List.fold_left
      (fun acc (queue, st, n) ->
        let c =
          match List.assoc_opt queue acc with
          | Some c -> c
          | None -> { queue; available = 0; blocked = 0; running = 0 }
        in
        (queue, add c st n) :: List.remove_assoc queue acc)
      [] rows
  in
  List.sort
    (fun (a : queue_count) (b : queue_count) -> String.compare a.queue b.queue)
    (List.map snd by_queue)

(* A period past this many milliseconds is more nanoseconds than a span
   holds. *)
let per_ms_json =
  Wiretype.int_bounded ~min:0
    ~max:(Int64.to_int (Int64.div Int64.max_int 1_000_000L))
    ()

type rate = { attempts : int; per_ms : int [@with per_ms_json] }
[@@deriving wiretype]

let ms_of span =
  Int64.to_int (Int64.div (Mtime.Span.to_uint64_ns span) 1_000_000L)

let of_rate r : Spool.Queue.rate =
  { attempts = r.attempts; per = Mtime.Span.(r.per_ms * ms) }

let rate (r : Spool.Queue.rate) =
  { attempts = r.attempts; per_ms = ms_of r.per }

type queue = {
  name : string;
  paused : bool;
  limit : int option;
  rate : rate option;
  per_partition : bool;
}
[@@deriving wiretype]

let queue (q : Spool.Queue.t) =
  {
    name = q.name;
    paused = q.paused;
    limit = q.running;
    rate = Option.map rate q.rate;
    per_partition = q.per_partition;
  }

type limits = { running : int option; rate : rate option; per_partition : bool }
[@@deriving wiretype]

type runner_queue = { queue : string; slots : int } [@@deriving wiretype]

type runner = {
  id : string;
  host : string;
  pid : int;
  queues : runner_queue list;
  started_at : Ptime.t;
  seen_at : Ptime.t;
}
[@@deriving wiretype]

let runner (r : Spool.Runner.info) =
  {
    id = r.id;
    host = r.host;
    pid = r.pid;
    queues = List.map (fun (queue, slots) -> { queue; slots }) r.queues;
    started_at = r.started_at;
    seen_at = r.seen_at;
  }

type schedule = {
  name : string;
  cron : string;
  zone : string;
  kind : string;
  queue : string;
  next_at : Ptime.t;
  last_at : Ptime.t option;
}
[@@deriving wiretype]

let schedule (s : Spool.Schedule.info) =
  {
    name = s.name;
    cron = s.cron;
    zone = s.zone;
    kind = s.kind;
    queue = s.queue;
    next_at = s.next_at;
    last_at = s.last_at;
  }

type point = {
  minute : Ptime.t;
  completed : int;
  retried : int;
  discarded : int;
}
[@@deriving wiretype]

type day = { queue : string; completed : int; retried : int; discarded : int }
[@@deriving wiretype]

type queue_kind = { queue : string; kind : string } [@@deriving wiretype]

type chart = {
  until : Ptime.t;
  points : point list;
  day : day list;
  kinds : queue_kind list;
}
[@@deriving wiretype]

module Minutes = Map.Make (Ptime)

(* The minute an instant falls in, by the epoch's whole minutes. *)
let minute_of t =
  let d, ps = Ptime.Span.to_d_ps (Ptime.to_span t) in
  let s = Int64.to_int (Int64.div ps 1_000_000_000_000L) in
  match
    Ptime.Span.of_d_ps
      (d, Int64.mul (Int64.of_int (s - (s mod 60))) 1_000_000_000_000L)
  with
  | Some span -> Option.value (Ptime.of_span span) ~default:t
  | None -> t

module Names = Map.Make (String)

module Pairs = Map.Make (struct
  type t = string * string

  let compare (a, b) (c, d) =
    match String.compare a c with 0 -> String.compare b d | n -> n
end)

let chart ~until ~minutes ~day:in_day =
  let point_add (p : point) (s : Spool.Stats.t) =
    match s.outcome with
    | Completed -> { p with completed = p.completed + s.count }
    | Retried -> { p with retried = p.retried + s.count }
    | Discarded -> { p with discarded = p.discarded + s.count }
  in
  let seconds =
    List.fold_left
      (fun acc (s : Spool.Stats.t) ->
        let p =
          let m = minute_of s.second in
          match Minutes.find_opt m acc with
          | Some p -> p
          | None -> { minute = m; completed = 0; retried = 0; discarded = 0 }
        in
        Minutes.add p.minute (point_add p s) acc)
      Minutes.empty minutes
  in
  let day_add (d : day) (s : Spool.Stats.t) =
    match s.outcome with
    | Completed -> { d with completed = d.completed + s.count }
    | Retried -> { d with retried = d.retried + s.count }
    | Discarded -> { d with discarded = d.discarded + s.count }
  in
  let queues =
    List.fold_left
      (fun acc (s : Spool.Stats.t) ->
        let d =
          match Names.find_opt s.queue acc with
          | Some d -> d
          | None ->
              { queue = s.queue; completed = 0; retried = 0; discarded = 0 }
        in
        Names.add s.queue (day_add d s) acc)
      Names.empty in_day
  in
  let kinds =
    List.fold_left
      (fun acc (s : Spool.Stats.t) ->
        Pairs.add (s.queue, s.kind)
          ({ queue = s.queue; kind = s.kind } : queue_kind)
          acc)
      Pairs.empty in_day
  in
  {
    until;
    points = List.map snd (Minutes.bindings seconds);
    day = List.map snd (Names.bindings queues);
    kinds = List.map snd (Pairs.bindings kinds);
  }

type selection = {
  ids : Spool.Id.t list;
      [@with Wiretype.list ~min_items:1 ~max_items:500 id_json]
}
[@@deriving wiretype]

type outcome = {
  applied : Spool.Id.t list; [@with Wiretype.list id_json]
  skipped : Spool.Id.t list; [@with Wiretype.list id_json]
}
[@@deriving wiretype]

type enqueued = { id : Spool.Id.t [@with id_json] } [@@deriving wiretype]
