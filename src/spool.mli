(** A durable queue of work in an application's own Postgres.

    A job is a row, written through the caller's connection in the transaction
    that made the work owed -- so a rollback leaves no job, and a commit leaves
    one nothing can lose. A {!Runner} claims it under a lease, runs its handler
    outside every transaction, retries a failure after a backoff, and finishes
    it once in the table however often it was attempted:

    {[
    let receipt = Spool.Kind.make ~queue:"mail" "receipt.send" order_json

    (* in the transaction that took the order *)
    let* _ = Spool.enqueue conn ~now ~unique:order.id receipt order in

    (* where the program starts *)
    let* runner =
      Spool.Runner.create ~sw ~net ~mono_clock ~now ~queues:[ ("mail", 2) ]
        [ Spool.handle receipt (fun _job order -> send_receipt order) ]
        conninfo
    in
    Spool.Runner.start runner
    ]}

    {b A job runs at least once and finishes once.} A handler whose effect must
    happen once is idempotent, or keyed by the job. Every instant the package
    writes or compares is the [now] it is given, a [Ptime.t], and every wait is
    an [Mtime.Span.t] on the monotonic clock it is given; a job's payload
    reaches no log line. *)

(** {1 The table} *)

val table : string
(** [spool_jobs], the table spool keeps its jobs in. It is made by spool's own
    migrations, installed with the package in [share/spool/migrations] and
    applied beside the application's: [rowtype-migrate up --source spool]. A
    runner refuses to start on a database where it is missing or behind. *)

val statements : Rowtype.any list
(** Every statement the package runs, for [Rowtype_postgres.verify] beside the
    application's own. *)

(** {1 Kinds} *)

module Id : sig
  type t
  (** A job's handle: a counter, so never put where a stranger could read it. *)

  val equal : t -> t -> bool
  val to_string : t -> string
end

module Kind : sig
  type 'a t
  (** A kind of job: its name, the description of its payload, and how it is
      run. *)

  val make :
    ?queue:string ->
    ?priority:int ->
    ?max_attempts:int ->
    ?timeout:Mtime.Span.t ->
    ?backoff:(attempt:int -> Mtime.Span.t) ->
    ?keep:bool ->
    string ->
    'a Wiretype.t ->
    'a t
  (** [make name payload]. [queue] is ["default"] unless given; [priority] 0,
      the first, of 0 to 9; [max_attempts] 20; [timeout] five minutes, an
      attempt's bound; [backoff] how long the attempt after [attempt] waits,
      unless given 15 s doubled each attempt to at most six hours, spread by a
      tenth either way, so twenty attempts span about two and a half days;
      [keep] [true], and [false] deletes a job the moment it completes, so a
      payload that should not outlive its work does not.

      [payload] describes an object, each member named for what it holds --
      [{"order": "..."}], never the bare key -- so a row says what each value is
      of, and a kind gains a member, with an [~absent], without a new name.

      A kind's name is its identity in the table: renaming one strands its
      waiting jobs, so a changed payload shape is a new name. An empty name or
      queue, a priority outside 0 to 9, attempts under one, a timeout of zero,
      or a payload that is not an object, raise [Invalid_argument]: a kind is a
      constant written in source. *)

  val name : 'a t -> string
end

(** {1 Enqueueing} *)

val enqueue :
  ?at:Ptime.t ->
  ?after:Mtime.Span.t ->
  ?priority:int ->
  ?unique:string ->
  ?expires_at:Ptime.t ->
  Rowtype_postgres.conn ->
  now:Ptime.t ->
  'a Kind.t ->
  'a ->
  ( Id.t,
    [> Rowtype.error
    | `Unencodable of Wiretype.Unwritable.t
    | `Bad_priority of int ] )
  result
(** Write a job through the caller's connection, in its transaction, and nothing
    else: its runner hears of it when the transaction commits, and never if it
    rolls back. It runs at [at], or [after] [now], or now.

    A [unique] key already waiting in this kind is that job, brought to the
    earlier instant and the higher priority, and its id is the answer: asking
    twice is one job. A key is unique among waiting jobs only, so a change made
    while its job runs is a job of its own. A job past [expires_at] is discarded
    unrun. A [priority] is a value a caller may compute, so one outside 0 to 9
    is refused rather than raised. *)

(** {1 An operator's hand} *)

type state =
  | Available  (** waiting, or scheduled, or to be retried *)
  | Running
  | Completed
  | Discarded  (** failed on its last attempt, expired, or given up *)
  | Cancelled

type failed = { attempt : int; at : Ptime.t; reason : string }
(** A failed attempt: which, when, and why, in the handler's words. *)

type info = {
  id : Id.t;
  queue : string;
  kind : string;
  state : state;
  priority : int;
  attempt : int;  (** attempts begun *)
  max_attempts : int;
  scheduled_at : Ptime.t;
  inserted_at : Ptime.t;
  finished_at : Ptime.t option;
  errors : failed list;  (** oldest first *)
}

val find :
  Rowtype_postgres.conn -> Id.t -> (info option, [> Rowtype.error ]) result

val counts :
  Rowtype_postgres.conn ->
  ((string * state * int) list, [> Rowtype.error ]) result
(** How many jobs each queue holds in each state. *)

val cancel :
  Rowtype_postgres.conn ->
  now:Ptime.t ->
  Id.t ->
  (bool, [> Rowtype.error ]) result
(** A waiting job never runs; a running one is stopped at its runner's next
    heartbeat. [false]: it had finished. *)

val retry :
  Rowtype_postgres.conn ->
  now:Ptime.t ->
  Id.t ->
  (Id.t option, [> Rowtype.error ]) result
(** A discarded or cancelled job, available now from its first attempt, its
    failed attempts' reasons kept. Where a job of its kind already waits under
    its key, that one is the answer and the retried row stays as it was, so one
    key never runs twice. [None]: it had not been discarded or cancelled. *)

(** {1 Running} *)

type job = {
  id : Id.t;
  attempt : int;
  max_attempts : int;
  inserted_at : Ptime.t;
}
(** The attempt a handler is running: [attempt] counts from one. *)

(** Why an attempt failed, in words for an operator. A raise is a {!Retry} whose
    reason names the exception's constructor and never its argument. *)
type failure =
  | Retry of string  (** after the kind's backoff *)
  | Retry_in of Mtime.Span.t * string
      (** after so long: an upstream said when *)
  | Discard of string
      (** never again, and no attempt used: it cannot succeed, however long it
          waits *)

type handler

val handle : 'a Kind.t -> (job -> 'a -> (unit, failure) result) -> handler

module Runner : sig
  type t

  type refused =
    | Unrun_queue of string  (** a handler's kind is in no queue it runs *)
    | Two_handlers of string  (** one kind handled twice *)
    | No_concurrency of string  (** a queue given fewer than one slot *)
    | Unreachable of Rowtype.error  (** its pool could not be made *)
    | Unmigrated of string list
        (** the table is missing, or behind what spool runs: spool's migrations
            are not applied, and each problem says where *)

  val refused_to_string : refused -> string

  val create :
    sw:Eio.Switch.t ->
    net:_ Eio.Net.t ->
    mono_clock:_ Eio.Time.Mono.t ->
    now:(unit -> Ptime.t) ->
    ?pool_size:int ->
    ?poll:Mtime.Span.t ->
    ?lease:Mtime.Span.t ->
    ?retain_completed:Mtime.Span.t ->
    ?retain_failed:Mtime.Span.t ->
    ?observe:Rowtype_postgres.observer ->
    queues:(string * int) list ->
    handler list ->
    Rowtype_postgres.Conninfo.t ->
    (t, refused) result
  (** A runner of the named queues, each with how many of its jobs may run at
      once, claiming only the kinds it has a handler for. Its connections are
      its own -- a pool of [pool_size] (2), and a listener beside it -- because
      one borrowed from the application's would lose its heartbeats exactly when
      the application is busiest, and a lost heartbeat is a job run twice.
      [observe] watches every statement on that pool, as an application's own.
      Before it answers, it checks every statement spool runs against the
      database, and on a table that is missing or behind it closes its pool and
      is [Unmigrated].

      [poll] (a second) is how often a queue looks for due jobs between
      notifications; [lease] (a minute) how long a claim holds without renewal,
      renewed every quarter of it; [retain_completed] (a day) and
      [retain_failed] (fourteen days) how long finished rows stay. Nothing runs
      until {!start}. *)

  val start : t -> unit
  (** A fiber per queue, the heartbeat and the listener, on [sw]. *)

  val drain : t -> ((Id.t * state) list, string) result
  (** Every job due at [now ()], run one at a time in this fiber through the
      runner's own claim and finish, until none is: what each attempt left the
      job, in order. A test's, with a clock it moves. *)

  val stop : ?grace:Mtime.Span.t -> t -> unit
  (** Claim nothing more; wait up to [grace] (ten seconds) for running jobs; put
      back the rest, their attempt not counted, since they were interrupted and
      did not fail; close. Returns within the grace and one statement. *)
end
