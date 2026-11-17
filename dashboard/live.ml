open Spindle.Syntax

let src = Logs.Src.create "spool-dashboard" ~doc:"spool's dashboard"

module Log = (val Logs.src_log src : Logs.LOG)

type stream

let counts : (Wire.queue_count list, stream) Spindle.Event.kind =
  Spindle.Event.json "counts" (Wiretype.list Wire.queue_count_json)

let queues : (Wire.queue list, stream) Spindle.Event.kind =
  Spindle.Event.json "queues" (Wiretype.list Wire.queue_json)

let runners : (Wire.runner list, stream) Spindle.Event.kind =
  Spindle.Event.json "runners" (Wiretype.list Wire.runner_json)

let schedules : (Wire.schedule list, stream) Spindle.Event.kind =
  Spindle.Event.json "schedules" (Wiretype.list Wire.schedule_json)

let chart : (Wire.chart, stream) Spindle.Event.kind =
  Spindle.Event.json "chart" Wire.chart_json

(* The page's build, by the name of its script, which its content's hash is
   in: what a page open across an upgrade reads to know it is out of date. *)
let build : (string, stream) Spindle.Event.kind =
  Spindle.Event.json "build" Wiretype.string

let allowed : (Wire.action list, stream) Spindle.Event.kind =
  Spindle.Event.json "allowed" (Wiretype.list Wire.action_json)

let build_name =
  List.find_opt
    (fun f ->
      String.starts_with ~prefix:"assets/" f && String.ends_with ~suffix:".js" f)
    Bundle.file_list
  |> Option.value ~default:""

let declared =
  Spindle.Event.
    [
      declare build;
      declare allowed;
      declare counts;
      declare queues;
      declare runners;
      declare schedules;
      declare chart;
    ]

type t = {
  hub : (unit, stream Spindle.Event.t) Spindle.Broadcast.t;
  reading : bool Atomic.t;
  last : stream Spindle.Event.t list Atomic.t;
      (** the latest event of each part, as every viewer has been sent it *)
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
  stream_for : Mtime.Span.t;
}

let topic = "live"

(* A read a second is what "live" promises: the state a viewer sees is at
   most this old. *)
let every = Mtime.Span.(1 * s)

(* The chart's window, an hour of whole minutes; the day its finished counts
   are summed over; and the last two minutes, the only statistics a runner
   still adds to, so the only ones read again each second. *)
let charted_s = 60 * 60
let day_s = 24 * 60 * 60
let fresh_s = 2 * 60

let create ~mono_clock ~stream_for =
  {
    hub = Spindle.Broadcast.create ();
    reading = Atomic.make false;
    last = Atomic.make [];
    mono_clock :> Eio.Time.Mono.ty Eio.Resource.t;
    stream_for;
  }

let before now s =
  Option.value (Ptime.sub_span now (Ptime.Span.of_int_s s)) ~default:Ptime.epoch

(* The request's instant carried forward by the monotonic clock, so a reader
   needs no wall clock of its own. *)
let later now span =
  let ns = Mtime.Span.to_uint64_ns span in
  let day_ns = 86_400_000_000_000L in
  match
    Ptime.Span.of_d_ps
      ( Int64.to_int (Int64.unsigned_div ns day_ns),
        Int64.mul (Int64.unsigned_rem ns day_ns) 1000L )
  with
  | None -> now
  | Some span -> Option.value (Ptime.add_span now span) ~default:now

let name event = Option.value (Spindle.Event.name event) ~default:""

(* What changed since the last read is published, and the whole is kept for
   the next viewer to start from. *)
let publish t events =
  let last = Atomic.get t.last in
  List.iter
    (fun event ->
      let same =
        List.exists
          (fun old ->
            String.equal (name old) (name event)
            && String.equal
                 (Spindle.Event.to_string old)
                 (Spindle.Event.to_string event))
          last
      in
      if not same then Spindle.Broadcast.publish t.hub ~topic event)
    events;
  Atomic.set t.last events

(* Reads once a second until cancelled, which is its viewer going. The day's
   statistics are read whole once, then its last minutes each second, which
   are the only ones a runner still adds to. *)
let read t ~pool ~now ~start =
  let rec tick day =
    let now = later now (Mtime.span start (Eio.Time.Mono.now t.mono_clock)) in
    let until = Wire.minute_of now in
    let charted = before until charted_s
    and in_day = before now day_s
    and fresh = before now fresh_s in
    let since = match day with None -> in_day | Some _ -> fresh in
    let read =
      Spindle_postgres.Pool.use pool (fun conn ->
          let* counts = Spool.counts ~finished:false conn in
          let* queues = Spool.Queue.list conn in
          let* runners = Spool.Runner.list conn in
          let* schedules = Spool.Schedule.list conn in
          let* stats = Spool.Stats.since conn since in
          Ok (counts, queues, runners, schedules, stats))
    in
    let day =
      match read with
      | Error e ->
          Log.warn (fun m ->
              m "The dashboard could not read the queue: %s"
                (Spindle_postgres.error_to_string e));
          day
      | Ok (c, q, r, s, stats) ->
          let recent (st : Spool.Stats.t) =
            (not (Ptime.is_earlier st.second ~than:charted))
            && Ptime.is_earlier st.second ~than:until
          and older (st : Spool.Stats.t) =
            (not (Ptime.is_earlier st.second ~than:in_day))
            && Ptime.is_earlier st.second ~than:fresh
          in
          let whole =
            match day with
            | None -> stats
            | Some day -> List.filter older day @ stats
          in
          publish t
            [
              Spindle.Event.make counts (Wire.queue_counts c);
              Spindle.Event.make queues (List.map Wire.queue q);
              Spindle.Event.make runners (List.map Wire.runner r);
              Spindle.Event.make schedules (List.map Wire.schedule s);
              Spindle.Event.make chart
                (Wire.chart ~until ~minutes:(List.filter recent whole)
                   ~day:whole);
            ];
          Some whole
    in
    Eio.Time.Mono.sleep_span t.mono_clock every;
    tick day
  in
  tick None

(* One reader a process: whoever holds the flag reads, and the rest look
   once a second whether it is free, so one that goes is replaced. *)
let rec take_turns t ~pool ~now ~start =
  if Atomic.compare_and_set t.reading false true then
    Fun.protect
      ~finally:(fun () -> Atomic.set t.reading false)
      (fun () -> read t ~pool ~now ~start)
  else begin
    Eio.Time.Mono.sleep_span t.mono_clock every;
    take_turns t ~pool ~now ~start
  end

let watch t ~pool ~now ~gone ~allowed:actions send =
  let start = Eio.Time.Mono.now t.mono_clock in
  Spindle.Broadcast.subscribe t.hub ~topic () (fun sub ->
      let* () = send (Spindle.Event.make build build_name) in
      let* () = send (Spindle.Event.make allowed actions) in
      let* () =
        List.fold_left
          (fun sent event ->
            let* () = sent in
            send event)
          (Ok ()) (Atomic.get t.last)
      in
      Eio.Fiber.first
        (fun () -> Spindle.Broadcast.forward ~until:gone sub send)
        (fun () ->
          Eio.Fiber.first
            (fun () -> take_turns t ~pool ~now ~start)
            (fun () ->
              Eio.Time.Mono.sleep_span t.mono_clock t.stream_for;
              Ok ())))
