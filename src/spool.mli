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

  val of_string : string -> t option
  (** An id as {!to_string} wrote it -- what an operator's screen sends back;
      [None] for any other text. *)
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
    ?partition:('a -> string) ->
    ?sensitive:bool ->
    string ->
    'a Wiretype.t ->
    'a t
  (** [make name payload]. [queue] is ["default"] unless given; [priority] 0,
      the first, of 0 to 9; [max_attempts] 20; [timeout] five minutes, an
      attempt's bound; [backoff] how long the attempt after [attempt] waits,
      unless given 15 s doubled each attempt to at most six hours, spread by a
      tenth either way, so twenty attempts span about two and a half days;
      [keep] [true], and [false] deletes a job the moment it completes, so a
      payload that should not outlive its work does not. [partition] names the
      partition a job of it is in -- its customer, its account -- written when
      it is enqueued: a queue limited per partition ({!Queue.set_limits})
      applies its limits to each, and takes them in turns. [sensitive] ([false])
      keeps its jobs' payloads from every answer of spool's -- {!find},
      {!val-jobs}, a dashboard over them -- as every payload is kept from every
      log line.

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
  ?unique_for:Mtime.Span.t ->
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
    is refused rather than raised.

    With [unique_for], the key holds for that long from this enqueue, whatever
    its job's state: an enqueue of the kind and key within it is answered with
    that job, waiting, running or finished, and its row is kept -- by pruning,
    and by a kind that keeps none, which keeps the row and not its payload --
    until the period ends. Without [unique], the period holds for the kind: at
    most one job of it enqueued in any such period. *)

val enqueue_many :
  ?at:Ptime.t ->
  ?after:Mtime.Span.t ->
  ?priority:int ->
  ?unique:('a -> string) ->
  ?expires_at:Ptime.t ->
  Rowtype_postgres.conn ->
  now:Ptime.t ->
  'a Kind.t ->
  'a list ->
  ( Id.t list,
    [> Rowtype.error
    | `Unencodable of Wiretype.Unwritable.t
    | `Bad_priority of int ] )
  result
(** Many jobs of one kind written in one statement, through the caller's
    connection and transaction, each as {!enqueue} would write it: [unique]
    gives each payload's key, and the first payload of a key stands for the
    rest. The answer is every job's id, each once and in no order -- what a job
    that waits for all of them is given. *)

(** {1 Workflows}

    A job may wait for others: it is [Blocked] until every one of them
    completed, then runs as any job does. One that ends otherwise -- discarded,
    cancelled, expired or deleted -- cancels every job that waits on it, however
    far down, each saying which job ended and how. A batch with a summary is a
    workflow of one level:

    {[
    let* rows = Spool.enqueue_many conn ~now import_row lines in
    let* _ = Spool.enqueue_after conn ~now ~waits_for:rows summary file in
    ]} *)

val enqueue_after :
  ?at:Ptime.t ->
  ?after:Mtime.Span.t ->
  ?priority:int ->
  ?expires_at:Ptime.t ->
  Rowtype_postgres.conn ->
  now:Ptime.t ->
  waits_for:Id.t list ->
  'a Kind.t ->
  'a ->
  ( Id.t,
    [> Rowtype.error
    | `Unencodable of Wiretype.Unwritable.t
    | `Bad_priority of int ] )
  result
(** {!enqueue}, the job waiting for [waits_for] to complete. One it waits for
    that is gone counts as completed, since a completed job of a kind that keeps
    none is deleted and the rest are pruned after; one already discarded or
    cancelled cancels it at once. It takes no unique key: a job blocked is in no
    key's fold, and released would meet the job its key already names. *)

(** {1 An operator's hand} *)

type state =
  | Available  (** waiting, or scheduled, or to be retried *)
  | Blocked  (** waiting for jobs it was enqueued after ({!enqueue_after}) *)
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
  payload : string option;
      (** its JSON, as an operator diagnosing it reads it; [None] for a kind
          made [~sensitive] *)
}

val find :
  Rowtype_postgres.conn -> Id.t -> (info option, [> Rowtype.error ]) result

type workflow = {
  jobs : info list;  (** every job connected to it, by id *)
  edges : (Id.t * Id.t) list;  (** [(job, waits_for)] *)
}

val workflow :
  Rowtype_postgres.conn -> Id.t -> (workflow, [> Rowtype.error ]) result
(** The jobs connected to one by waiting, either way, and how. A job no longer
    kept is in [edges] and not in [jobs]. *)

val counts :
  ?finished:bool ->
  Rowtype_postgres.conn ->
  ((string * state * int) list, [> Rowtype.error ]) result
(** How many jobs each queue holds in each state. [~finished:false] counts only
    what waits, is blocked and runs, from their indexes, without reading the
    finished rows retention keeps: what a page asking every second reads. *)

(** How an attempt that finished in a span came out. *)
type finished =
  | Succeeded  (** the job completed then *)
  | Failed  (** an attempt failed then, whether the job was retried or not *)
  | Either

val jobs :
  ?state:state ->
  ?queue:string ->
  ?kind:string ->
  ?finished:finished * Ptime.t * Ptime.t ->
  ?before:Id.t ->
  Rowtype_postgres.conn ->
  limit:int ->
  (info list, [> Rowtype.error ]) result
(** At most [limit] jobs, newest first, of a state, a queue and a kind where
    given; the next page is [~before] the last one's id.
    [~finished:(which, from, until)] keeps the jobs with an attempt that
    finished from [from] and before [until], as [which] says: what a chart's
    minute of {!Stats} counts, but for a completed job a kind that keeps none
    has deleted. *)

val cancel :
  Rowtype_postgres.conn ->
  now:Ptime.t ->
  Id.t ->
  (bool, [> Rowtype.error ]) result
(** A waiting job never runs; a running one is stopped at its runner's next
    heartbeat; and every job that waits on it, however far down, is cancelled
    with it. [false]: it had finished. *)

val retry :
  Rowtype_postgres.conn ->
  now:Ptime.t ->
  Id.t ->
  (Id.t option, [> Rowtype.error ]) result
(** A discarded or cancelled job, available now from its first attempt, its
    failed attempts' reasons kept. Where a job of its kind already waits under
    its key, that one is the answer and the retried row stays as it was, so one
    key never runs twice. [None]: it had not been discarded or cancelled. *)

val run_again :
  Rowtype_postgres.conn ->
  now:Ptime.t ->
  Id.t ->
  (Id.t option, [> Rowtype.error ]) result
(** A new job, a copy of this one -- its kind, queue, payload and settings --
    waiting now from its first attempt, whatever this one's state: its work done
    again, as an operator asks, so with no unique key and waiting for nothing.
    [None]: there is no such job, or it is gone. *)

val delete :
  Rowtype_postgres.conn ->
  now:Ptime.t ->
  Id.t ->
  (bool, [> Rowtype.error ]) result
(** The job gone, its row and all it said, whatever its state but running: a
    running job is cancelled first, and deleted once it has stopped. A job
    deleted before it completed cancels what waits on it, as a cancel does.
    [false]: it was running, or there was no such job. *)

(** A queue's settings every runner obeys, kept in the table and not in any
    runner's code: one number all of them read has one place, where two deploys
    cannot disagree on it. *)
module Queue : sig
  type rate = { attempts : int; per : Mtime.Span.t }
  (** At most [attempts] begun in any [per]. *)

  type t = {
    name : string;
    paused : bool;
    running : int option;
        (** how many of its jobs run at once across every runner, or of each
            partition's; none, no limit beyond each runner's slots *)
    rate : rate option;  (** across every runner, or each partition's *)
    per_partition : bool;
        (** whether [running] and [rate] hold for each partition, its partitions
            taken in turns *)
  }

  val list : Rowtype_postgres.conn -> (t list, [> Rowtype.error ]) result
  (** Every queue a runner has named, or an operator has paused, by name. *)

  val pause :
    Rowtype_postgres.conn ->
    now:Ptime.t ->
    string ->
    (unit, [> Rowtype.error ]) result
  (** No runner claims from it -- one started later among them -- until it is
      resumed; what runs, runs on. A queue no runner has named yet may be
      paused, and is then paused when one does. *)

  val resume :
    Rowtype_postgres.conn ->
    now:Ptime.t ->
    string ->
    (unit, [> Rowtype.error ]) result
  (** Claimed from again, its runners told when the caller's transaction
      commits. *)

  val set_limits :
    Rowtype_postgres.conn ->
    now:Ptime.t ->
    running:int option ->
    rate:rate option ->
    per_partition:bool ->
    string ->
    (unit, [> Rowtype.error | `Bad_limit of string ]) result
  (** The queue's limits, every one replaced: [running] how many of its jobs run
      at once, [rate] how many attempts begin in a period, each across every
      runner, and with [per_partition] each for every partition of it, as its
      kinds' [partition] names them. Every runner's slots still bound what it
      runs.

      With [per_partition], partitions are taken in turns -- each one's first
      job, then each one's second -- the one served longest ago first, so one
      partition's many does not keep another's few waiting; within a partition,
      jobs keep their order. A limited queue's claims are taken one at a time
      across its runners, under a lock of the queue's: a queue with neither
      limits nor partitions takes none. A limit that could never let a job run
      -- no slot, no attempt, or a period of nothing -- is [`Bad_limit], saying
      why. *)
end

(** What attempts came to, a row a second: what a dashboard charts. A runner
    counts each attempt in the transaction that records it, and prunes them as
    it prunes completed jobs. *)
module Stats : sig
  type outcome =
    | Completed
    | Retried  (** failed, to be attempted again *)
    | Discarded  (** failed on its last attempt, or given up *)

  type t = {
    second : Ptime.t;  (** the second the attempts finished in *)
    queue : string;
    kind : string;
    outcome : outcome;
    count : int;
    run : Mtime.Span.t;  (** how long they ran, together *)
    wait : Mtime.Span.t;
        (** how long, together, they waited past their scheduled instant before
            a runner claimed them *)
  }

  val since :
    Rowtype_postgres.conn -> Ptime.t -> (t list, [> Rowtype.error ]) result
  (** Every second from that instant on, oldest first. *)
end

(** Recurring jobs: a kind and its payload, enqueued at each tick of a cron
    expression read in a time zone.

    {[
    let nightly =
      Spool.Schedule.make ~name:"report.nightly" ~cron:"0 2 * * *"
        ~zone:"Europe/London" report { day = `Yesterday }
    ]}

    Every runner given a schedule holds it, and
    {b a tick is one job however many runners hold it}: its row's next tick is
    moved past now by the transaction that enqueues the tick's job, guarded by
    the value it read, so no leader is elected and none fails over. Ticks missed
    while no runner ran are enqueued once, the latest of them, so an outage does
    not flood its queue. A schedule's row keeps its next tick across deploys
    while its expression and zone stay the same, and starts again from now when
    either changes. *)
module Schedule : sig
  type t

  val make :
    name:string ->
    cron:string ->
    zone:string ->
    ?priority:int ->
    'a Kind.t ->
    'a ->
    t
  (** [cron] is five fields -- minute, hour, day of the month, month, day of the
      week -- each [*], a value, a range [a-b], a step [*/n] or [a-b/n], or a
      list of them, Sunday both 0 and 7; or one of [@hourly], [@daily],
      [@midnight], [@weekly], [@monthly], [@yearly], [@annually]. Where both
      days are restricted, a day either names is a tick, as cron has it.

      [zone] is required, a name of the tz database -- ["Europe/London"],
      ["UTC"] -- since a business's 08:00 is local and moves against UTC twice a
      year. A local time the zone's clock skips ticks at the instant the clock
      changes; one it repeats ticks once, at its first.

      An empty name, an expression that does not read or names no instant, a
      zone the tz database does not have, a priority outside 0 to 9 or a payload
      that cannot be written raise [Invalid_argument]: a schedule is a constant
      written in source. *)

  val name : t -> string

  val next : t -> after:Ptime.t -> Ptime.t option
  (** The first tick after [after], within about nine years. *)

  type info = {
    name : string;
    cron : string;
    zone : string;
    kind : string;
    queue : string;
    next_at : Ptime.t;
    last_at : Ptime.t option;  (** the tick last enqueued *)
  }

  val list : Rowtype_postgres.conn -> (info list, [> Rowtype.error ]) result
  (** Every schedule a runner has held, by name. *)

  val run_now :
    Rowtype_postgres.conn ->
    now:Ptime.t ->
    string ->
    (Id.t option, [> Rowtype.error ]) result
  (** Its job enqueued now, beside its ticks, which it does not move. [None]: no
      runner has held a schedule of that name. *)
end

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

val handle_committing :
  'a Kind.t ->
  (job ->
  'a ->
  (Rowtype_postgres.conn -> (unit, failure) result, failure) result) ->
  handler
(** As {!handle}, for work that ends in a write to the application's own tables:
    the handler does its work outside every transaction, as any does, and
    answers the write, which the runner makes in the transaction that completes
    the job -- after the statement guarded by the lease, so a runner whose lease
    was taken makes no write. The job is completed and the write made together,
    or neither: a write that answers a {!failure} rolls both back and is that
    failure, and one that raises is a {!Retry} named by its constructor. Its
    connection is the runner's own, on the database the runner was given.

    {[
    Spool.handle_committing receipt (fun _job order ->
        let url = Pdf.render order in
        Ok (fun conn -> Invoices.set_pdf conn order url))
    ]} *)

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
    | Two_schedules of string  (** one schedule's name given twice *)

  val refused_to_string : refused -> string

  type info = {
    id : string;  (** host, process and a draw *)
    host : string;
    pid : int;
    queues : (string * int) list;
        (** each queue it runs, with how many of its jobs at once *)
    started_at : Ptime.t;
    seen_at : Ptime.t;  (** its last heartbeat *)
  }
  (** A runner as it says it is running. *)

  val list : Rowtype_postgres.conn -> (info list, [> Rowtype.error ]) result
  (** The runners running, oldest first: each writes its row at its heartbeat
      and deletes it at {!stop}, and one a lease late is deleted by another. *)

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
    ?schedules:Schedule.t list ->
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

      [schedules] are held by this runner: each one's row written, and its ticks
      enqueued once they are due, into its kind's queue, which this runner need
      not run.

      [poll] (a second) is how often a queue looks for due jobs between
      notifications; [lease] (a minute) how long a claim holds without renewal,
      renewed every quarter of it; [retain_completed] (a day) and
      [retain_failed] (fourteen days) how long finished rows stay. Nothing runs
      until {!start}. *)

  val start : t -> unit
  (** A fiber per queue, the heartbeat and the listener, on [sw]. *)

  val drain : t -> ((Id.t * state) list, string) result
  (** Every tick due at [now ()] of the schedules it holds enqueued, then every
      job due, run one at a time in this fiber through the runner's own claim
      and finish, until none is: what each attempt left the job, in order. A
      test's, with a clock it moves. *)

  val stop : ?grace:Mtime.Span.t -> t -> unit
  (** Claim nothing more; wait up to [grace] (ten seconds) for running jobs; put
      back the rest, their attempt not counted, since they were interrupted and
      did not fail; close. Returns within the grace and one statement. *)
end
