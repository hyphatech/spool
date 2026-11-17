(** What the dashboard's routes read and answer, as wiretype descriptions: the
    one contract the page's client is printed from. *)

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

val actions : action list
(** Every action, in the order above. *)

val action_name : action -> string
(** As the wire writes it, [run_again]: for a policy's log line and span. *)

val id_json : Spool.Id.t Wiretype.t
(** A job's id, as text: a counter that may pass what a browser's integer holds.
*)

type state = Available | Blocked | Running | Completed | Discarded | Cancelled
[@@deriving wiretype]

val state : Spool.state -> state
val of_state : state -> Spool.state

(** How the attempts of a chart's minute came out, as the job list reads them:
    done, failed, or either. *)
type ended = Done | Failed | Either [@@deriving wiretype]

val finished : ended -> Spool.finished

type failed = { attempt : int; at : Ptime.t; reason : string }
[@@deriving wiretype]

type moment_outcome = Completed | Failed | Discarded [@@deriving wiretype]

type moment = {
  outcome : moment_outcome;
  attempt : int;  (** which attempt *)
  reason : string option;  (** a failure's, in the handler's words *)
}
[@@deriving wiretype]
(** What a job's attempt came to within a chart's minute. *)

type job = {
  id : Spool.Id.t; [@with id_json]
  queue : string;
  kind : string;
  state : state;
  priority : int;
  attempt : int;  (** attempts begun *)
  max_attempts : int;
  scheduled_at : Ptime.t;
  inserted_at : Ptime.t;
  finished_at : Ptime.t option;
  last_error : string option;  (** the reason of its latest failed attempt *)
  in_minute : moment option;
      (** listed by a chart's minute: what its attempt came to then *)
}
[@@deriving wiretype]
(** A job as a list shows it. *)

val job : ?minute:Ptime.t * Ptime.t * ended -> Spool.info -> job
(** [minute]: listed by a chart's minute, from and until, and the outcome asked
    for, which its [in_minute] says. *)

type edge = {
  job : Spool.Id.t; [@with id_json]
  waits_for : Spool.Id.t; [@with id_json]
}
[@@deriving wiretype]

type payload =
  | Shown of { value : Wiretype.Value.t }
  | Hidden  (** its kind was made [~sensitive] *)
[@@deriving wiretype]

type detail = {
  job : job;
  errors : failed list;  (** oldest first *)
  payload : payload;
  workflow : job list;
      (** the jobs connected to it by waiting, it among them *)
  edges : edge list;
}
[@@deriving wiretype]

val detail : Spool.info -> Spool.workflow -> detail

type queue_count = {
  queue : string;
  available : int;
  blocked : int;
  running : int;
}
[@@deriving wiretype]
(** What waits, is blocked and runs in a queue, exact. *)

val queue_counts : (string * Spool.state * int) list -> queue_count list

val per_ms_json : int Wiretype.t
(** A rate's period in milliseconds: none before nothing, and none past what a
    span holds in nanoseconds. *)

type rate = { attempts : int; per_ms : int [@with per_ms_json] }
[@@deriving wiretype]
(** At most [attempts] begun in any [per_ms] milliseconds. *)

val of_rate : rate -> Spool.Queue.rate

type queue = {
  name : string;
  paused : bool;
  limit : int option;  (** how many run at once across every runner *)
  rate : rate option;
  per_partition : bool;
}
[@@deriving wiretype]

val queue : Spool.Queue.t -> queue

type limits = { running : int option; rate : rate option; per_partition : bool }
[@@deriving wiretype]
(** A queue's limits as an operator sets them, every one replaced: what
    {!Spool.Queue.set_limits} takes. *)

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

val runner : Spool.Runner.info -> runner

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

val schedule : Spool.Schedule.info -> schedule

type point = {
  minute : Ptime.t;  (** the minute's start *)
  completed : int;
  retried : int;
  discarded : int;
}
[@@deriving wiretype]
(** The attempts that finished in one minute, every queue's. *)

type day = { queue : string; completed : int; retried : int; discarded : int }
[@@deriving wiretype]
(** A queue's attempts in the last 24 hours, summed from spool's statistics. *)

type queue_kind = { queue : string; kind : string } [@@deriving wiretype]
(** A kind and a queue it ran in: one, unless a deploy moved it. *)

type chart = {
  until : Ptime.t;  (** the start of the minute the chart ends before *)
  points : point list;
      (** each whole minute of the last hour, oldest first; a minute with none
          is not listed *)
  day : day list;
  kinds : queue_kind list;
      (** every kind attempted in the day, with each queue it was attempted in,
          by queue and then kind *)
}
[@@deriving wiretype]

val minute_of : Ptime.t -> Ptime.t
(** The start of the minute an instant falls in. *)

val chart :
  until:Ptime.t -> minutes:Spool.Stats.t list -> day:Spool.Stats.t list -> chart
(** [minutes] are the statistics charted, [day] the day's, which hold them;
    [until] is the start of the current minute, which is not charted, since it
    is not over. *)

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
(** What an action came to: the jobs it changed, and those it left as they were,
    as spool answered for each. *)

type enqueued = { id : Spool.Id.t [@with id_json] } [@@deriving wiretype]
