(** The queue's live state, read once a second by one fiber of the process while
    anyone watches, and sent to every viewer as what changed. *)

type stream
(** The live route's events. *)

val build : (string, stream) Spindle.Event.kind
(** The page's build, sent first to every viewer: a page that sees another than
    the one it first saw was opened before an upgrade, and reloads. *)

val allowed : (Wire.action list, stream) Spindle.Event.kind
(** What the viewer may do, sent second: the page shows no more. *)

val counts : (Wire.queue_count list, stream) Spindle.Event.kind
val queues : (Wire.queue list, stream) Spindle.Event.kind
val runners : (Wire.runner list, stream) Spindle.Event.kind
val schedules : (Wire.schedule list, stream) Spindle.Event.kind
val chart : (Wire.chart, stream) Spindle.Event.kind
val declared : stream Spindle.Event.declared list

type t

module Log : Logs.LOG
(** The dashboard's source, [spool-dashboard]. *)

val create : mono_clock:_ Eio.Time.Mono.t -> stream_for:Mtime.Span.t -> t
(** A stream lasts [stream_for], then ends, for the page to open the next. *)

val watch :
  t ->
  pool:Spindle_postgres.Pool.t ->
  now:Ptime.t ->
  gone:unit Eio.Promise.t ->
  allowed:Wire.action list ->
  stream Spindle.Event.stream
(** A viewer's stream: what they are [allowed], the state last read, then each
    part as it changes, until the viewer goes, falls too far behind, or the
    stream has lasted its time. While it watches it takes its turn at reading:
    of every viewer of the process one reads, and when that one goes, another
    takes over within a second. [now] is the request's instant, which the
    reader's monotonic clock carries forward. *)
