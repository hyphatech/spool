(* See spool.mli. *)

module S = Rowtype
module Pg = Rowtype_postgres

let src = Logs.Src.create "spool" ~doc:"A queue of jobs in Postgres"

module Log = (val Logs.src_log src : Logs.LOG)

let ( let* ) = Result.bind

(* ------------------------------------------------------------------ *)
(* Instants and spans

   Every instant here is the caller's [now], a [Ptime.t], and every wait an
   [Mtime.Span.t]. What a wait is between two instants, and an instant a
   span on from another, is worked out by the three functions below and
   nowhere else. *)

let day_ns = 86_400_000_000_000L

(* A span as a Ptime one: whole days and the picoseconds into the last. An
   [Mtime.Span.t] is unsigned, so it is divided as one. *)
let ptime_span span =
  let ns = Mtime.Span.to_uint64_ns span in
  Ptime.Span.v
    ( Int64.to_int (Int64.unsigned_div ns day_ns),
      Int64.mul (Int64.unsigned_rem ns day_ns) 1000L )

(* [span] after [t], or the latest instant there is when that is later. *)
let later t span =
  Option.value (Ptime.add_span t (ptime_span span)) ~default:Ptime.max

(* [span] before [t], or the earliest instant there is. *)
let earlier t span =
  Option.value (Ptime.sub_span t (ptime_span span)) ~default:Ptime.min

(* How long from [now] until [deadline], rounded up to the nanosecond, and
   zero once it has passed, since a wait cannot be negative: the one place
   a wait until an instant is worked out, as Spindle's [until] is for a
   program built on it, which this package does not link. *)
let until ~now deadline =
  match Ptime.Span.to_d_ps (Ptime.diff deadline now) with
  | d, _ when d < 0 -> Mtime.Span.zero
  (* Past what a span holds, about 584 years: as long as one can be. *)
  | d, _ when d >= 106_751 -> Mtime.Span.max_span
  | d, ps ->
      let ns = Int64.div (Int64.add ps 999L) 1000L in
      Mtime.Span.of_uint64_ns (Int64.add (Int64.mul (Int64.of_int d) day_ns) ns)

(* A share of a span: a lease's quarter, a sixteenth. *)
let part span n =
  Mtime.Span.of_uint64_ns
    (Int64.unsigned_div (Mtime.Span.to_uint64_ns span) (Int64.of_int n))

let shorter a b = if Mtime.Span.is_shorter a ~than:b then a else b

(* ------------------------------------------------------------------ *)
(* The table *)

(* Every "{t}" in a statement is the table's name, spool's own and one
   identifier: the only thing spliced into the SQL here. *)
let named t sql =
  let marker = "{t}" in
  let n = String.length marker in
  let b = Buffer.create (String.length sql) in
  let rec go i =
    if i >= String.length sql then ()
    else if
      i + n <= String.length sql && String.equal (String.sub sql i n) marker
    then (
      Buffer.add_string b t;
      go (i + n))
    else (
      Buffer.add_char b sql.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

(* ------------------------------------------------------------------ *)
(* States *)

type state = Available | Blocked | Running | Completed | Discarded | Cancelled

let state_to_string = function
  | Available -> "available"
  | Blocked -> "blocked"
  | Running -> "running"
  | Completed -> "completed"
  | Discarded -> "discarded"
  | Cancelled -> "cancelled"

let state_of_string = function
  | "available" -> Ok Available
  | "blocked" -> Ok Blocked
  | "running" -> Ok Running
  | "completed" -> Ok Completed
  | "discarded" -> Ok Discarded
  | "cancelled" -> Ok Cancelled
  | other -> Error (Printf.sprintf "%S is no job's state" other)

let state_ty = S.parse S.text ~parse:state_of_string ~print:state_to_string

type failed = { attempt : int; at : Ptime.t; reason : string }

(* A failed attempt's instant as the errors column writes it, whole epoch
   milliseconds, which an operator reads in the row: the statements that
   append one write it so, and this is the one reading of it. *)
let at_json =
  let ms_ps = 1_000_000_000L and day_ms = 86_400_000 in
  Wiretype.kind ~kind:"epoch milliseconds"
    ~parse:(fun ms ->
      let d = (ms / day_ms) - if ms mod day_ms < 0 then 1 else 0 in
      let into = Int64.mul (Int64.of_int (ms - (d * day_ms))) ms_ps in
      match Option.bind (Ptime.Span.of_d_ps (d, into)) Ptime.of_span with
      | Some t -> Ok t
      | None -> Error "This is not an instant of the years 0000 to 9999.")
    ~print:(fun t ->
      let d, ps = Ptime.Span.to_d_ps (Ptime.to_span t) in
      (d * day_ms) + Int64.to_int (Int64.div ps ms_ps))
    Wiretype.int

let failed_json =
  Wiretype.Object.map ~kind:"failed" (fun attempt at reason ->
      { attempt; at; reason })
  |> Wiretype.Object.mem "attempt" Wiretype.int ~enc:(fun (f : failed) ->
      f.attempt)
  |> Wiretype.Object.mem "at" at_json ~enc:(fun (f : failed) -> f.at)
  |> Wiretype.Object.mem "reason" Wiretype.string ~enc:(fun (f : failed) ->
      f.reason)
  |> Wiretype.Object.finish

let errors_json = Wiretype.list failed_json

(* What an attempt came to, as the statistics count it. *)
type stat_outcome = Counted_completed | Counted_retried | Counted_discarded

let stat_outcome_ty =
  S.parse S.text
    ~parse:(function
      | "completed" -> Ok Counted_completed
      | "retried" -> Ok Counted_retried
      | "discarded" -> Ok Counted_discarded
      | other -> Error (Printf.sprintf "%S is no attempt's outcome" other))
    ~print:(function
      | Counted_completed -> "completed"
      | Counted_retried -> "retried"
      | Counted_discarded -> "discarded")

(* ------------------------------------------------------------------ *)
(* Statements *)

(* A claimed row: id, kind, payload, attempt, attempts allowed, enqueued. *)
type claimed = int * string * string * int * int * Ptime.t

(* An instant written into the errors column, in whole epoch milliseconds,
   rounded toward the past. *)
let millis_of param =
  Printf.sprintf "floor(extract(epoch from %s::timestamptz) * 1000)::bigint"
    param

(* A failed attempt, appended to the row by the statement that records it. *)
let appended =
  "errors || jsonb_build_array(jsonb_build_object('attempt', attempt, 'at', "
  ^ millis_of "$5" ^ ", 'reason', $6::text))"

type statements = {
  insert :
    ( (string
      * string
      * string
      * int
      * int
      * Ptime.t
      * Ptime.t option
      * string option
      * Ptime.t
      * string option
      * Ptime.t option)
      * bool,
      int )
    S.statement;
  insert_many :
    ( string
      * string
      * string list
      * int
      * int
      * Ptime.t
      * Ptime.t option
      * Ptime.t
      * string option list
      * string option list
      * bool,
      int list )
    S.statement;
  lock_key : (string * string, unit) S.statement;
  held_key : (string * string * Ptime.t, int option) S.statement;
  complete_emptied : (int * string * int * Ptime.t, int) S.statement;
  insert_blocked :
    ( string
      * string
      * string
      * int
      * int
      * Ptime.t
      * Ptime.t option
      * Ptime.t
      * string option
      * bool,
      int )
    S.statement;
  add_dependencies : (int * int list, unit) S.statement;
  dependency_states : (int list, (int * state) list) S.statement;
  release : (int, string option) S.statement;
  unblock : (int, string list) S.statement;
  cancel_dependents : (int * Ptime.t * string, int) S.statement;
  linked : (int, int list) S.statement;
  edges : (int list, (int * int) list) S.statement;
  find_many :
    ( int list,
      ((int
       * string
       * string
       * state
       * int
       * int
       * int
       * Ptime.t
       * Ptime.t
       * Ptime.t option
       * string)
      * string option)
      list )
    S.statement;
  copy : (int * Ptime.t, (int * string) option) S.statement;
  notify : (string * string, unit) S.statement;
  find :
    ( int,
      ((int
       * string
       * string
       * state
       * int
       * int
       * int
       * Ptime.t
       * Ptime.t
       * Ptime.t option
       * string)
      * string option)
      option )
    S.statement;
  counts : (unit, (string * state * int) list) S.statement;
  counts_unfinished : (unit, (string * state * int) list) S.statement;
  jobs :
    ( state option
      * string option
      * string option
      * int option
      * int
      * string option
      * Ptime.t option
      * Ptime.t option,
      ((int
       * string
       * string
       * state
       * int
       * int
       * int
       * Ptime.t
       * Ptime.t
       * Ptime.t option
       * string)
      * string option)
      list )
    S.statement;
  cancel : (int * Ptime.t, int) S.statement;
  waiting_key : (int, int option) S.statement;
  revive : (int * Ptime.t, string option) S.statement;
  claim :
    ( string * Ptime.t * Ptime.t * string * string list * int,
      claimed list )
    S.statement;
  soonest : (string * Ptime.t, Ptime.t option) S.statement;
  renew : (string * Ptime.t * int list, int list) S.statement;
  complete : (int * string * int * Ptime.t, int) S.statement;
  delete_done : (int * string * int * Ptime.t, int) S.statement;
  again : (int * string * int * Ptime.t * Ptime.t * string, int) S.statement;
  give_up : (int * string * int * Ptime.t * Ptime.t * string, int) S.statement;
  discard : (int * string * int * Ptime.t * Ptime.t * string, int) S.statement;
  put_back : (string * Ptime.t * int list, int) S.statement;
  rescue : (Ptime.t, (int * state) list) S.statement;
  delete : (int, state option) S.statement;
  name_queues : (string list * Ptime.t, unit) S.statement;
  set_paused : (string * bool * Ptime.t, unit) S.statement;
  queues :
    ( unit,
      (string * bool * int option * int option * int64 option * bool) list )
    S.statement;
  set_limits :
    ( string * int option * int option * int64 option * bool * Ptime.t,
      unit )
    S.statement;
  settings :
    ( string,
      (bool * int option * int option * int64 option * bool) option )
    S.statement;
  lock_queue : (string, unit) S.statement;
  forget_starts : (string * Ptime.t, unit) S.statement;
  claim_limited :
    ( string
      * Ptime.t
      * Ptime.t
      * string
      * string list
      * int
      * int option
      * int option
      * Ptime.t
      * bool,
      claimed list )
    S.statement;
  prune_partitions : (Ptime.t, unit) S.statement;
  hold_schedule :
    ( string
      * string
      * string
      * string
      * string
      * string
      * int
      * int
      * string option
      * Ptime.t
      * bool,
      unit )
    S.statement;
  next_ticks : (string list, (string * Ptime.t) list) S.statement;
  advance : (string * Ptime.t * Ptime.t * Ptime.t, int) S.statement;
  enqueue_tick : (string * Ptime.t, (int * string) option) S.statement;
  schedules :
    ( unit,
      (string * string * string * string * string * Ptime.t * Ptime.t option)
      list )
    S.statement;
  seen : (string * string * int * string * Ptime.t * Ptime.t, unit) S.statement;
  forget_runner : (string, unit) S.statement;
  forget_lapsed : (Ptime.t, unit) S.statement;
  runners :
    ( unit,
      (string * string * int * string * Ptime.t * Ptime.t) list )
    S.statement;
  count_attempt :
    (int * string * int * Ptime.t * stat_outcome * int64, unit) S.statement;
  stats :
    ( Ptime.t,
      (Ptime.t * string * string * stat_outcome * int * int64 * int64) list )
    S.statement;
  prune_stats : (Ptime.t, unit) S.statement;
  expire : (Ptime.t, int list) S.statement;
  prune : (Ptime.t * Ptime.t * Ptime.t, int) S.statement;
}

let make t =
  let q sql = named t sql in
  (* Finishing counts only from the runner holding that attempt's lease: a
     count of none is a lease taken, or a job cancelled, and changes
     nothing. *)
  let held = "id = $1 and state = 'running' and runner = $2 and attempt = $3" in
  {
    insert =
      S.find
        ~params:
          S.(
            t2
              (t11 text text text int int instant (opt instant) (opt text)
                 instant (opt text) (opt instant))
              bool)
        ~row:S.int
        (q
           {|insert into {t} (queue, kind, payload, priority, state, attempt,
     max_attempts, scheduled_at, expires_at, unique_key, inserted_at, errors,
     partition_key, unique_until, sensitive)
   values ($1, $2, $3::jsonb, $4, 'available', 0, $5, $6, $7, $8, $9, '[]',
     $10, $11, $12)
   on conflict (kind, unique_key)
     where state = 'available' and unique_key is not null
   do update set scheduled_at = least({t}.scheduled_at, excluded.scheduled_at),
                 priority = least({t}.priority, excluded.priority),
                 unique_until = greatest({t}.unique_until, excluded.unique_until)
   returning id|});
    insert_many =
      S.list
        ~params:
          S.(
            t11 text text (array text) int int instant (opt instant) instant
              (array (opt text))
              (array (opt text))
              bool)
        ~row:S.int
        (q
           {|insert into {t} (queue, kind, payload, priority, state, attempt,
     max_attempts, scheduled_at, expires_at, unique_key, inserted_at, errors,
     partition_key, sensitive)
   select $1, $2, u.p::jsonb, $4, 'available', 0, $5, $6, $7, u.k, $8, '[]', u.w,
     $11
   from unnest($3::text[], $9::text[], $10::text[]) with ordinality
     as u(p, k, w, n)
   order by u.n
   on conflict (kind, unique_key)
     where state = 'available' and unique_key is not null
   do update set scheduled_at = least({t}.scheduled_at, excluded.scheduled_at),
                 priority = least({t}.priority, excluded.priority)
   returning id|});
    (* Enqueues of one kind and key with a period are taken one at a time,
       so two transactions cannot each find the key free. *)
    lock_key =
      S.exec
        ~params:S.(t2 text text)
        "select pg_advisory_xact_lock(hashtext($1), hashtext($2))";
    held_key =
      S.find_opt
        ~params:S.(t3 text text instant)
        ~row:S.int
        (q
           {|select id from {t}
   where kind = $1 and unique_key = $2 and unique_until > $3
   order by id desc limit 1|});
    insert_blocked =
      S.find
        ~params:
          S.(
            t10 text text text int int instant (opt instant) instant (opt text)
              bool)
        ~row:S.int
        (q
           {|insert into {t} (queue, kind, payload, priority, state, attempt,
     max_attempts, scheduled_at, expires_at, inserted_at, errors, partition_key,
     sensitive)
   values ($1, $2, $3::jsonb, $4, 'blocked', 0, $5, $6, $7, $8, '[]', $9, $10)
   returning id|});
    add_dependencies =
      S.exec
        ~params:S.(t2 int (array int))
        {|insert into spool_dependencies (job, on_job)
   select $1, unnest($2::bigint[]) on conflict do nothing|};
    dependency_states =
      S.list
        ~params:S.(array int)
        ~row:S.(t2 int state_ty)
        (q "select id, state from {t} where id = any($1)");
    (* A blocked job is waiting while one job it waits for is there and not
       completed: one gone was completed by a kind that keeps none, or
       pruned after it completed. *)
    release =
      S.find_opt ~params:S.int ~row:S.text
        (q
           {|update {t} j set state = 'available'
   where j.id = $1 and j.state = 'blocked'
     and not exists (select 1 from spool_dependencies d
       join {t} o on o.id = d.on_job
       where d.job = j.id and o.state <> 'completed')
   returning queue|});
    unblock =
      S.list ~params:S.int ~row:S.text
        (q
           {|update {t} j set state = 'available'
   where j.state = 'blocked'
     and j.id in (select job from spool_dependencies where on_job = $1)
     and not exists (select 1 from spool_dependencies d
       join {t} o on o.id = d.on_job
       where d.job = j.id and o.state <> 'completed')
   returning queue|});
    (* Every blocked job that waits on it, however far down, cancelled,
       saying which job ended and how. *)
    cancel_dependents =
      S.exec_count
        ~params:S.(t3 int instant text)
        (q
           ({|with recursive doomed(id) as (
     select job from spool_dependencies where on_job = $1
     union
     select d.job from spool_dependencies d join doomed on d.on_job = doomed.id)
   update {t} set state = 'cancelled', finished_at = $2,
     errors = errors || jsonb_build_array(jsonb_build_object('attempt',
       attempt, 'at', |}
          ^ millis_of "$2"
          ^ {|, 'reason', 'job ' || $1 || ' it waits for ' || $3))
   where id in (select id from doomed) and state = 'blocked'|}
           ));
    linked =
      S.list ~params:S.int ~row:S.int
        {|with recursive linked(id) as (
     select $1::bigint
     union
     select case when d.job = l.id then d.on_job else d.job end
     from spool_dependencies d join linked l on d.job = l.id or d.on_job = l.id)
   select id::bigint from linked order by id|};
    edges =
      S.list
        ~params:S.(array int)
        ~row:S.(t2 int int)
        {|select job, on_job from spool_dependencies
   where job = any($1) order by job, on_job|};
    find_many =
      S.list
        ~params:S.(array int)
        ~row:
          S.(
            t2
              (t11 int text text state_ty int int int instant instant
                 (opt instant) text)
              (opt text))
        (q
           {|select id, queue, kind, state, priority, attempt, max_attempts,
     scheduled_at, inserted_at, finished_at, errors::text,
     case when sensitive then null else payload::text end
   from {t} where id = any($1) order by id|});
    (* A job's copy: its kind, queue, payload and settings, waiting now from
       its first attempt, with no key and nothing it waits for, since what
       asks for it again is an operator and not the work. *)
    copy =
      S.find_opt
        ~params:S.(t2 int instant)
        ~row:S.(t2 int text)
        (q
           {|insert into {t} (queue, kind, payload, priority, state, attempt,
     max_attempts, scheduled_at, inserted_at, errors, partition_key, sensitive)
   select queue, kind, payload, priority, 'available', 0, max_attempts, $2, $2,
     '[]', partition_key, sensitive
   from {t} where id = $1
   returning id, queue|});
    notify = S.exec ~params:S.(t2 text text) "select pg_notify($1, $2)";
    find =
      S.find_opt ~params:S.int
        ~row:
          S.(
            t2
              (t11 int text text state_ty int int int instant instant
                 (opt instant) text)
              (opt text))
        (q
           {|select id, queue, kind, state, priority, attempt, max_attempts,
     scheduled_at, inserted_at, finished_at, errors::text,
     case when sensitive then null else payload::text end
   from {t} where id = $1|});
    (* Newest first, a page at a time from below an id, each filter by a
       column an index leads with. *)
    jobs =
      S.list
        ~params:
          S.(
            t8 (opt state_ty) (opt text) (opt text) (opt int) int (opt text)
              (opt instant) (opt instant))
        ~row:
          S.(
            t2
              (t11 int text text state_ty int int int instant instant
                 (opt instant) text)
              (opt text))
        (q
           ({|select id, queue, kind, state, priority, attempt, max_attempts,
     scheduled_at, inserted_at, finished_at, errors::text,
     case when sensitive then null else payload::text end
   from {t}
   where ($1::text is null or state = $1) and ($2::text is null or queue = $2)
     and ($3::text is null or kind = $3) and ($4::bigint is null or id < $4)
     and ($6::text is null
       or ($6 in ('succeeded', 'either') and state = 'completed'
           and finished_at >= $7 and finished_at < $8)
       or ($6 in ('failed', 'either')
           and (scheduled_at >= $7 or finished_at >= $7)
           and exists (select 1 from jsonb_array_elements(errors) e
             where (e->>'at')::bigint >= |}
          ^ millis_of "$7" ^ {|
               and (e->>'at')::bigint < |}
          ^ millis_of "$8" ^ {|)))
   order by id desc limit $5|}));
    counts =
      S.list ~params:S.unit
        ~row:S.(t3 text state_ty int)
        (q
           {|select queue, state, count(*)::integer from {t}
   group by queue, state order by queue, state|});
    (* What waits and runs, from the partial indexes, without the finished
       rows a day's retention keeps. *)
    counts_unfinished =
      S.list ~params:S.unit
        ~row:S.(t3 text state_ty int)
        (q
           {|select queue, state, count(*)::integer from {t}
   where state in ('available', 'blocked', 'running')
   group by queue, state order by queue, state|});
    cancel =
      S.exec_count
        ~params:S.(t2 int instant)
        (q
           {|update {t} set state = 'cancelled', finished_at = $2, runner = null,
     lease_ends_at = null
   where id = $1 and state in ('available', 'running')|});
    waiting_key =
      S.find_opt ~params:S.int ~row:S.int
        (q
           {|select w.id from {t} w
   join {t} d on w.kind = d.kind and w.unique_key = d.unique_key
   where d.id = $1 and d.state in ('discarded', 'cancelled')
     and w.state = 'available'|});
    revive =
      S.find_opt
        ~params:S.(t2 int instant)
        ~row:S.text
        (q
           {|update {t} j set attempt = 0, scheduled_at = $2, finished_at = null,
     state = case when exists (select 1 from spool_dependencies d
       join {t} o on o.id = d.on_job
       where d.job = j.id and o.state <> 'completed')
     then 'blocked' else 'available' end
   where id = $1 and state in ('discarded', 'cancelled')
   returning queue|});
    claim =
      S.list
        ~params:S.(t6 text instant instant text (array text) int)
        ~row:S.(t6 int text text int int instant)
        (q
           {|update {t} set state = 'running', runner = $1, attempt = attempt + 1,
     attempted_at = $2, lease_ends_at = $3
   where id in (
     select id from {t}
     where queue = $4 and state = 'available' and scheduled_at <= $2
       and (expires_at is null or expires_at > $2) and kind = any($5)
       and not exists (select 1 from spool_queues where name = $4 and paused)
     order by priority, scheduled_at, id
     limit $6
     for update skip locked)
   returning id, kind, payload::text, attempt, max_attempts, inserted_at|});
    soonest =
      S.find
        ~params:S.(t2 text instant)
        ~row:S.(opt instant)
        (q
           {|select min(scheduled_at) from {t}
   where queue = $1 and state = 'available' and scheduled_at > $2|});
    renew =
      S.list
        ~params:S.(t3 text instant (array int))
        ~row:S.int
        (q
           {|update {t} set lease_ends_at = $2
   where runner = $1 and state = 'running' and id = any($3)
   returning id|});
    complete =
      S.exec_count
        ~params:S.(t4 int text int instant)
        (q
           ({|update {t} set state = 'completed', finished_at = $4, runner = null,
     lease_ends_at = null
   where |}
          ^ held));
    (* A kind that keeps nothing keeps a row whose key still holds, and
       only that: its payload goes. *)
    delete_done =
      S.exec_count
        ~params:S.(t4 int text int instant)
        (q
           ("delete from {t} where " ^ held
          ^ " and (unique_until is null or unique_until <= $4)"));
    complete_emptied =
      S.exec_count
        ~params:S.(t4 int text int instant)
        (q
           ({|update {t} set state = 'completed', finished_at = $4, runner = null,
     lease_ends_at = null, payload = '{}'::jsonb
   where |}
          ^ held));
    again =
      S.exec_count
        ~params:S.(t6 int text int instant instant text)
        (q
           ({|update {t} set state = 'available', scheduled_at = $4, runner = null,
     lease_ends_at = null, errors = |}
          ^ appended ^ " where " ^ held));
    give_up =
      S.exec_count
        ~params:S.(t6 int text int instant instant text)
        (q
           ({|update {t} set state = 'discarded', finished_at = $4, runner = null,
     lease_ends_at = null, errors = |}
          ^ appended ^ " where " ^ held));
    (* A discard is no attempt's failure: what it says is true however long
       the job waits, so the attempt it began is handed back. *)
    discard =
      S.exec_count
        ~params:S.(t6 int text int instant instant text)
        (q
           ({|update {t} set state = 'discarded', finished_at = $4, runner = null,
     lease_ends_at = null, attempt = attempt - 1, errors = |}
          ^ appended ^ " where " ^ held));
    put_back =
      S.exec_count
        ~params:S.(t3 text instant (array int))
        (q
           {|update {t} set state = 'available', attempt = attempt - 1,
     scheduled_at = $2, runner = null, lease_ends_at = null
   where runner = $1 and state = 'running' and id = any($3)|});
    rescue =
      S.list ~params:S.instant
        ~row:S.(t2 int state_ty)
        (q
           ({|update {t} set
     state = case when attempt >= max_attempts then 'discarded'
                  else 'available' end,
     finished_at = case when attempt >= max_attempts then $1 end,
     scheduled_at = $1, runner = null, lease_ends_at = null,
     errors = errors || jsonb_build_array(jsonb_build_object('attempt',
       attempt, 'at', |}
          ^ millis_of "$1"
          ^ {|, 'reason', 'lease lapsed'))
   where state = 'running' and lease_ends_at < $1
   returning id, state|}
           ));
    delete =
      S.find_opt ~params:S.int ~row:state_ty
        (q
           "delete from {t} where id = $1 and state <> 'running' returning \
            state");
    name_queues =
      S.exec
        ~params:S.(t2 (array text) instant)
        {|insert into spool_queues (name, paused, updated_at)
   select unnest($1::text[]), false, $2
   on conflict (name) do nothing|};
    set_paused =
      S.exec
        ~params:S.(t3 text bool instant)
        {|insert into spool_queues (name, paused, updated_at) values ($1, $2, $3)
   on conflict (name) do update
     set paused = excluded.paused, updated_at = excluded.updated_at|};
    queues =
      S.list ~params:S.unit
        ~row:S.(t6 text bool (opt int) (opt int) (opt int64) bool)
        {|select name, paused, running_limit, rate_attempts, rate_per_us,
     per_partition
   from spool_queues order by name|};
    set_limits =
      S.exec
        ~params:S.(t6 text (opt int) (opt int) (opt int64) bool instant)
        {|insert into spool_queues (name, paused, running_limit, rate_attempts,
     rate_per_us, per_partition, updated_at)
   values ($1, false, $2, $3, $4, $5, $6)
   on conflict (name) do update
     set running_limit = excluded.running_limit,
         rate_attempts = excluded.rate_attempts,
         rate_per_us = excluded.rate_per_us,
         per_partition = excluded.per_partition,
         updated_at = excluded.updated_at|};
    settings =
      S.find_opt ~params:S.text
        ~row:S.(t5 bool (opt int) (opt int) (opt int64) bool)
        {|select paused, running_limit, rate_attempts, rate_per_us, per_partition
   from spool_queues where name = $1|};
    (* Claims from a limited queue are taken one at a time across every
       runner, so a limit two runners count at once is still one limit. *)
    lock_queue =
      S.exec ~params:S.text
        "select pg_advisory_xact_lock(hashtext('spool_queues'), hashtext($1))";
    forget_starts =
      S.exec
        ~params:S.(t2 text instant)
        "delete from spool_starts where queue = $1 and at <= $2";
    (* A queue's due jobs, each partition's in its own order, taken in
       turns -- every partition's first, then every one's second -- and the
       partition served longest ago first within a turn; a partition at its
       limit or its rate gives none. Without partitions the queue is one. *)
    claim_limited =
      S.list
        ~params:
          S.(
            t10 text instant instant text (array text) int (opt int) (opt int)
              instant bool)
        ~row:S.(t6 int text text int int instant)
        (q
           {|with
   running as (
     select case when $10 then coalesce(partition_key, '') else '' end as p,
       count(*)::integer as n
     from {t} where queue = $4 and state = 'running' group by 1),
   started as (
     select case when $10 then partition_key else '' end as p,
       count(*)::integer as n
     from spool_starts where queue = $4 and at > $9 group by 1),
   due as (
     select j.id, j.priority, j.scheduled_at, d.p,
       coalesce(r.n, 0) as running, coalesce(s.n, 0) as started,
       w.claimed_at,
       row_number() over (partition by d.p
         order by j.priority, j.scheduled_at, j.id) as turn
     from {t} j
     cross join lateral (select case when $10
       then coalesce(j.partition_key, '') else '' end as p) d
     left join running r on r.p = d.p
     left join started s on s.p = d.p
     left join spool_partitions w on w.queue = $4 and w.partition_key = d.p
     where j.queue = $4 and j.state = 'available' and j.scheduled_at <= $2
       and (j.expires_at is null or j.expires_at > $2) and j.kind = any($5)),
   chosen as (
     select id, p from due
     where ($7::integer is null or turn <= $7::integer - running)
       and ($8::integer is null or turn <= $8::integer - started)
     order by turn, claimed_at nulls first, priority, scheduled_at, id
     limit $6),
   claimed as (
     update {t} set state = 'running', runner = $1, attempt = attempt + 1,
       attempted_at = $2, lease_ends_at = $3
     where id in (select id from chosen)
     returning id, kind, payload::text, attempt, max_attempts, inserted_at),
   counted as (
     insert into spool_starts (queue, partition_key, at)
     select $4, c.p, $2 from chosen c where $8::integer is not null),
   served as (
     insert into spool_partitions (queue, partition_key, claimed_at)
     select distinct $4, c.p, $2::timestamptz from chosen c where $10
     on conflict (queue, partition_key)
       do update set claimed_at = excluded.claimed_at)
 select id, kind, payload, attempt, max_attempts, inserted_at from claimed|});
    prune_partitions =
      S.exec ~params:S.instant
        "delete from spool_partitions where claimed_at < $1";
    (* A schedule's row as the code holding it says, its next tick kept
       unless its expression or zone changed, so a deploy neither skips nor
       repeats a tick. *)
    hold_schedule =
      S.exec
        ~params:
          S.(t11 text text text text text text int int (opt text) instant bool)
        {|insert into spool_schedules (name, expression, zone, kind, queue,
     payload, priority, max_attempts, partition_key, next_at, sensitive)
   values ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, $10, $11)
   on conflict (name) do update set
     sensitive = excluded.sensitive,
     kind = excluded.kind, queue = excluded.queue, payload = excluded.payload,
     priority = excluded.priority, max_attempts = excluded.max_attempts,
     partition_key = excluded.partition_key,
     next_at = case
       when spool_schedules.expression = excluded.expression
        and spool_schedules.zone = excluded.zone
       then spool_schedules.next_at else excluded.next_at end,
     expression = excluded.expression, zone = excluded.zone|};
    next_ticks =
      S.list
        ~params:S.(array text)
        ~row:S.(t2 text instant)
        "select name, next_at from spool_schedules where name = any($1)";
    advance =
      S.exec_count
        ~params:S.(t4 text instant instant instant)
        {|update spool_schedules set next_at = $3, last_at = $4
   where name = $1 and next_at = $2|};
    enqueue_tick =
      S.find_opt
        ~params:S.(t2 text instant)
        ~row:S.(t2 int text)
        (q
           {|insert into {t} (queue, kind, payload, priority, state, attempt,
     max_attempts, scheduled_at, inserted_at, errors, partition_key, sensitive)
   select queue, kind, payload, priority, 'available', 0, max_attempts, $2, $2,
     '[]', partition_key, sensitive
   from spool_schedules where name = $1
   returning id, queue|});
    schedules =
      S.list ~params:S.unit
        ~row:S.(t7 text text text text text instant (opt instant))
        {|select name, expression, zone, kind, queue, next_at, last_at
   from spool_schedules order by name|};
    seen =
      S.exec
        ~params:S.(t6 text text int text instant instant)
        {|insert into spool_runners (id, host, pid, queues, started_at, seen_at)
   values ($1, $2, $3, $4::jsonb, $5, $6)
   on conflict (id) do update set seen_at = excluded.seen_at|};
    forget_runner =
      S.exec ~params:S.text "delete from spool_runners where id = $1";
    forget_lapsed =
      S.exec ~params:S.instant "delete from spool_runners where seen_at < $1";
    runners =
      S.list ~params:S.unit
        ~row:S.(t6 text text int text instant instant)
        {|select id, host, pid, queues::text, started_at, seen_at
   from spool_runners order by started_at, id|};
    (* Counted from the row before the statement that finishes it changes
       it, under the same guard, so an attempt whose lease was taken is
       counted by nobody. *)
    count_attempt =
      S.exec
        ~params:S.(t6 int text int instant stat_outcome_ty int64)
        (q
           ({|insert into spool_stats
     (second, queue, kind, outcome, count, run_us, wait_us)
   select date_trunc('second', $4::timestamptz), queue, kind, $5, 1, $6,
     greatest(0, floor(extract(epoch from attempted_at - scheduled_at)
       * 1000000))::bigint
   from {t} where |}
          ^ held
          ^ {|
   on conflict (second, queue, kind, outcome) do update
     set count = spool_stats.count + 1,
         run_us = spool_stats.run_us + excluded.run_us,
         wait_us = spool_stats.wait_us + excluded.wait_us|}
           ));
    stats =
      S.list ~params:S.instant
        ~row:S.(t7 instant text text stat_outcome_ty int int64 int64)
        {|select second, queue, kind, outcome, count, run_us, wait_us
   from spool_stats where second >= $1
   order by second, queue, kind, outcome|};
    prune_stats =
      S.exec ~params:S.instant "delete from spool_stats where second < $1";
    expire =
      S.list ~params:S.instant ~row:S.int
        (q
           ({|update {t} set state = 'discarded', finished_at = $1,
     errors = errors || jsonb_build_array(jsonb_build_object('attempt',
       attempt, 'at', |}
          ^ millis_of "$1"
          ^ {|, 'reason', 'expired'))
   where state = 'available' and expires_at <= $1
   returning id|}
           ));
    prune =
      S.exec_count
        ~params:S.(t3 instant instant instant)
        (q
           {|delete from {t}
   where ((state = 'completed' and finished_at < $1)
       or (state in ('discarded', 'cancelled') and finished_at < $2))
     and (unique_until is null or unique_until <= $3)|});
  }

(* The table is spool's, made by its own migrations, which name it. *)
let table = "spool_jobs"

type table = { name : string; s : statements }

let the_table = { name = table; s = make table }

let statements =
  let s = the_table.s in
  S.
    [
      Any s.insert;
      Any s.insert_blocked;
      Any s.add_dependencies;
      Any s.dependency_states;
      Any s.release;
      Any s.unblock;
      Any s.cancel_dependents;
      Any s.linked;
      Any s.edges;
      Any s.find_many;
      Any s.insert_many;
      Any s.lock_key;
      Any s.held_key;
      Any s.complete_emptied;
      Any s.copy;
      Any s.notify;
      Any s.find;
      Any s.counts;
      Any s.counts_unfinished;
      Any s.jobs;
      Any s.cancel;
      Any s.waiting_key;
      Any s.revive;
      Any s.claim;
      Any s.soonest;
      Any s.renew;
      Any s.complete;
      Any s.delete_done;
      Any s.again;
      Any s.give_up;
      Any s.discard;
      Any s.put_back;
      Any s.rescue;
      Any s.expire;
      Any s.prune;
      Any s.delete;
      Any s.name_queues;
      Any s.set_paused;
      Any s.queues;
      Any s.set_limits;
      Any s.settings;
      Any s.lock_queue;
      Any s.forget_starts;
      Any s.claim_limited;
      Any s.prune_partitions;
      Any s.hold_schedule;
      Any s.next_ticks;
      Any s.advance;
      Any s.enqueue_tick;
      Any s.schedules;
      Any s.seen;
      Any s.forget_runner;
      Any s.forget_lapsed;
      Any s.runners;
      Any s.count_attempt;
      Any s.stats;
      Any s.prune_stats;
    ]

(* ------------------------------------------------------------------ *)
(* Kinds *)

module Id = struct
  type t = int

  let equal = Int.equal
  let to_string = string_of_int

  (* Digits alone, since [int_of_string_opt] also reads a sign, a base and
     underscores, none of which [to_string] writes; ids count from one. *)
  let of_string s =
    if
      String.length s > 0
      && String.for_all (function '0' .. '9' -> true | _ -> false) s
    then
      match int_of_string_opt s with
      | Some n when n > 0 -> Some n
      | Some _ | None -> None
    else None
end

module Kind = struct
  type 'a t = {
    name : string;
    queue : string;
    priority : int;
    max_attempts : int;
    timeout : Mtime.Span.t;
    backoff : attempt:int -> Mtime.Span.t;
    keep : bool;
    partition : ('a -> string) option;
    sensitive : bool;
    payload : 'a Wiretype.t;
  }

  (* Doubling from 15 s to at most six hours, spread by a tenth either way
     so the retries after one outage do not arrive together. Random's is
     fine: nothing here is a secret. *)
  let backoff ~attempt =
    let base =
      15_000. *. Float.pow 2. (float_of_int (Int.max 0 (attempt - 1)))
    in
    let base = Float.min base 21_600_000. in
    let spread = base /. 10. in
    let millis = int_of_float (base -. spread +. Random.float (2. *. spread)) in
    Mtime.Span.(millis * ms)

  (* A payload is an object, so a kind can gain a member without a new
     name, and a row says what each value is of: a bare key names nothing
     to an operator reading the table. *)
  let rec is_object : type a. a Wiretype.Shape.t -> bool = function
    | Object _ -> true
    | Map (_, m) -> is_object m.inner
    | Rec l -> is_object (Lazy.force l)
    | Null _ | Bool | Int _ | Int64 _ | Number _ | String _ | Enum _ | List _
    | Tuple _ | Dict _ | Nullable _ | Any _ | Value ->
        false

  let make ?(queue = "default") ?(priority = 0) ?(max_attempts = 20)
      ?(timeout = Mtime.Span.(5 * min)) ?(backoff = backoff) ?(keep = true)
      ?partition ?(sensitive = false) name payload =
    let refuse what =
      invalid_arg (Printf.sprintf "Spool.Kind.make %S: %s" name what)
    in
    if String.length name = 0 then refuse "a kind needs a name";
    if String.length queue = 0 then refuse "a queue needs a name";
    if priority < 0 || priority > 9 then refuse "a priority is 0 to 9";
    if max_attempts < 1 then refuse "a job needs an attempt";
    if Mtime.Span.equal timeout Mtime.Span.zero then
      refuse "a timeout is above zero";
    if not (is_object payload) then refuse "a payload is an object";
    {
      name;
      queue;
      priority;
      max_attempts;
      timeout;
      backoff;
      keep;
      partition;
      sensitive;
      payload;
    }

  let name k = k.name
end

(* ------------------------------------------------------------------ *)
(* Enqueueing, and an operator's hand *)

let scheduled ~now ~at ~after =
  match (at, after) with
  | Some at, _ -> at
  | None, Some span -> later now span
  | None, None -> now

let enqueue ?at ?after ?priority ?unique ?unique_for ?expires_at conn ~now
    (kind : _ Kind.t) payload =
  let t = the_table in
  let priority = Option.value priority ~default:kind.priority in
  if priority < 0 || priority > 9 then Error (`Bad_priority priority)
  else
    let* text =
      Result.map_error
        (fun m -> `Unencodable m)
        (Wiretype.encode kind.payload payload)
    in
    (* A period without a key holds for the kind: the empty key. *)
    let unique =
      match unique_for with
      | Some _ -> Some (Option.value unique ~default:"")
      | None -> unique
    in
    let* held =
      match (unique_for, unique) with
      | Some _, Some key ->
          let* () = Pg.run conn t.s.lock_key (kind.name, key) in
          Pg.run conn t.s.held_key (kind.name, key, now)
      | _ -> Ok None
    in
    match held with
    | Some id -> Ok id
    | None ->
        let* id =
          Pg.run conn t.s.insert
            ( ( kind.queue,
                kind.name,
                text,
                priority,
                kind.max_attempts,
                scheduled ~now ~at ~after,
                expires_at,
                unique,
                now,
                Option.map (fun f -> f payload) kind.partition,
                Option.map (later now) unique_for ),
              kind.sensitive )
        in
        (* Heard when the caller's transaction commits, and never if it rolls
           back: a hint, which a runner's poll makes good. *)
        let* () = Pg.run conn t.s.notify (t.name, kind.queue) in
        Ok id

let enqueue_many ?at ?after ?priority ?unique ?expires_at conn ~now
    (kind : _ Kind.t) payloads =
  let t = the_table in
  let priority = Option.value priority ~default:kind.priority in
  if priority < 0 || priority > 9 then Error (`Bad_priority priority)
  else
    (* Two of one key in one statement would be one row updated twice,
       which Postgres refuses: the first of each key stands for the rest. *)
    let seen = Hashtbl.create 16 in
    let rec rows acc = function
      | [] -> Ok (List.rev acc)
      | p :: rest -> (
          let key = Option.map (fun f -> f p) unique in
          match key with
          | Some k when Hashtbl.mem seen k -> rows acc rest
          | Some _ | None -> (
              match Wiretype.encode kind.payload p with
              | Error m -> Error (`Unencodable m)
              | Ok text ->
                  Option.iter (fun k -> Hashtbl.replace seen k ()) key;
                  rows
                    ((text, key, Option.map (fun f -> f p) kind.partition)
                    :: acc)
                    rest))
    in
    let* rows = rows [] payloads in
    match rows with
    | [] -> Ok []
    | _ :: _ ->
        let* ids =
          Pg.run conn t.s.insert_many
            ( kind.queue,
              kind.name,
              List.map (fun (p, _, _) -> p) rows,
              priority,
              kind.max_attempts,
              scheduled ~now ~at ~after,
              expires_at,
              now,
              List.map (fun (_, k, _) -> k) rows,
              List.map (fun (_, _, w) -> w) rows,
              kind.sensitive )
        in
        let* () = Pg.run conn t.s.notify (t.name, kind.queue) in
        Ok (List.sort_uniq Int.compare ids)

type info = {
  id : Id.t;
  queue : string;
  kind : string;
  state : state;
  priority : int;
  attempt : int;
  max_attempts : int;
  scheduled_at : Ptime.t;
  inserted_at : Ptime.t;
  finished_at : Ptime.t option;
  errors : failed list;
  payload : string option;
}

let info_of_row
    ( ( id,
        queue,
        kind,
        state,
        priority,
        attempt,
        max_attempts,
        scheduled_at,
        inserted_at,
        finished_at,
        errors ),
      payload ) =
  match Wiretype.decode errors_json errors with
  | Error problems ->
      Error
        (`Db
           ("a job's errors could not be read: "
           ^ Wiretype.Problem.list_to_string problems))
  | Ok errors ->
      Ok
        {
          id;
          queue;
          kind;
          state;
          priority;
          attempt;
          max_attempts;
          scheduled_at;
          inserted_at;
          finished_at;
          errors;
          payload;
        }

let find conn id =
  let* row = Pg.run conn the_table.s.find id in
  match row with
  | None -> Ok None
  | Some row ->
      let* info = info_of_row row in
      Ok (Some info)

(* What waits on a job that ended otherwise than completed, cancelled with
   it, saying how. *)
let doom conn ~now id how =
  let* n = Pg.run conn the_table.s.cancel_dependents (id, now, how) in
  if n > 0 then
    Log.warn (fun m -> m "%d jobs waiting on job %d cancelled: it %s" n id how);
  Ok ()

(* What waits on a job that completed, released where nothing else it waits
   for is left, its queues told. *)
let release_dependents conn id =
  let t = the_table in
  let* queues = Pg.run conn t.s.unblock id in
  List.fold_left
    (fun acc queue ->
      let* () = acc in
      Pg.run conn t.s.notify (t.name, queue))
    (Ok ())
    (List.sort_uniq String.compare queues)

let enqueue_after ?at ?after ?priority ?expires_at conn ~now ~waits_for
    (kind : _ Kind.t) payload =
  let t = the_table in
  let priority = Option.value priority ~default:kind.priority in
  if priority < 0 || priority > 9 then Error (`Bad_priority priority)
  else
    let* text =
      Result.map_error
        (fun m -> `Unencodable m)
        (Wiretype.encode kind.payload payload)
    in
    let* id =
      Pg.run conn t.s.insert_blocked
        ( kind.queue,
          kind.name,
          text,
          priority,
          kind.max_attempts,
          scheduled ~now ~at ~after,
          expires_at,
          now,
          Option.map (fun f -> f payload) kind.partition,
          kind.sensitive )
    in
    let* () = Pg.run conn t.s.add_dependencies (id, waits_for) in
    let* states = Pg.run conn t.s.dependency_states waits_for in
    let ended =
      List.find_map
        (fun (on, (st : state)) ->
          match st with
          | Discarded -> Some (on, "was discarded")
          | Cancelled -> Some (on, "was cancelled")
          | Available | Blocked | Running | Completed -> None)
        states
    in
    let* () =
      match ended with
      | Some (on, how) ->
          let* _ = Pg.run conn t.s.cancel_dependents (on, now, how) in
          Ok ()
      | None -> (
          let* released = Pg.run conn t.s.release id in
          match released with
          | Some queue -> Pg.run conn t.s.notify (t.name, queue)
          | None -> Ok ())
    in
    Ok id

type workflow = { jobs : info list; edges : (Id.t * Id.t) list }

let workflow conn id =
  let t = the_table in
  let* ids = Pg.run conn t.s.linked id in
  let* rows = Pg.run conn t.s.find_many ids in
  let* jobs =
    List.fold_left
      (fun acc row ->
        let* acc = acc in
        let* info = info_of_row row in
        Ok (info :: acc))
      (Ok []) rows
  in
  let* edges = Pg.run conn t.s.edges ids in
  Ok { jobs = List.rev jobs; edges }

let counts ?(finished = true) conn =
  Pg.run conn
    (if finished then the_table.s.counts else the_table.s.counts_unfinished)
    ()

type finished = Succeeded | Failed | Either

let jobs ?state ?queue ?kind ?finished ?before conn ~limit =
  let mode, from, until =
    match finished with
    | None -> (None, None, None)
    | Some (which, from, until) ->
        ( Some
            (match which with
            | Succeeded -> "succeeded"
            | Failed -> "failed"
            | Either -> "either"),
          Some from,
          Some until )
  in
  let* rows =
    Pg.run conn the_table.s.jobs
      (state, queue, kind, before, Int.max 0 limit, mode, from, until)
  in
  let* infos =
    List.fold_left
      (fun acc row ->
        let* acc = acc in
        let* info = info_of_row row in
        Ok (info :: acc))
      (Ok []) rows
  in
  Ok (List.rev infos)

let cancel conn ~now id =
  let* n = Pg.run conn the_table.s.cancel (id, now) in
  if n = 0 then Ok false
  else
    let* () = doom conn ~now id "was cancelled" in
    Ok true

let retry conn ~now id =
  let t = the_table in
  let* waiting = Pg.run conn t.s.waiting_key id in
  match waiting with
  | Some w -> Ok (Some w)
  | None -> (
      let* revived = Pg.run conn t.s.revive (id, now) in
      match revived with
      | None -> Ok None
      | Some queue ->
          let* () = Pg.run conn t.s.notify (t.name, queue) in
          Ok (Some id))

let run_again conn ~now id =
  let t = the_table in
  let* copied = Pg.run conn t.s.copy (id, now) in
  match copied with
  | None -> Ok None
  | Some (copy, queue) ->
      let* () = Pg.run conn t.s.notify (t.name, queue) in
      Ok (Some copy)

let delete conn ~now id =
  let* deleted = Pg.run conn the_table.s.delete id in
  match deleted with
  | None -> Ok false
  | Some Completed -> Ok true
  | Some (Available | Blocked | Running | Discarded | Cancelled) ->
      let* () = doom conn ~now id "was deleted" in
      Ok true

let us_of span = Int64.unsigned_div (Mtime.Span.to_uint64_ns span) 1000L
let span_of_us us = Mtime.Span.of_uint64_ns (Int64.mul (Int64.max 0L us) 1000L)

module Queue = struct
  type rate = { attempts : int; per : Mtime.Span.t }

  type t = {
    name : string;
    paused : bool;
    running : int option;
    rate : rate option;
    per_partition : bool;
  }

  let list conn =
    let* rows = Pg.run conn the_table.s.queues () in
    Ok
      (List.map
         (fun (name, paused, running, attempts, per_us, per_partition) ->
           {
             name;
             paused;
             running;
             rate =
               (match (attempts, per_us) with
               | Some attempts, Some us ->
                   Some { attempts; per = span_of_us us }
               | _ -> None);
             per_partition;
           })
         rows)

  let set_limits conn ~now ~running ~rate ~per_partition name =
    let bad =
      match (running, rate) with
      | Some n, _ when n < 1 -> Some "a queue needs a slot to run anything"
      | _, Some r when r.attempts < 1 ->
          Some "a rate needs an attempt in its period"
      | _, Some r when Int64.equal (us_of r.per) 0L ->
          Some "a rate's period is a microsecond or more"
      | _ -> None
    in
    match bad with
    | Some why -> Error (`Bad_limit why)
    | None ->
        let* () =
          Pg.run conn the_table.s.set_limits
            ( name,
              running,
              Option.map (fun r -> r.attempts) rate,
              Option.map (fun r -> us_of r.per) rate,
              per_partition,
              now )
        in
        (* Its runners told, as a resume tells them, since a raised limit
           frees slots. *)
        Pg.run conn the_table.s.notify (the_table.name, name)

  let pause conn ~now name = Pg.run conn the_table.s.set_paused (name, true, now)

  (* A resumed queue's runners are told at once, as an enqueue tells them. *)
  let resume conn ~now name =
    let t = the_table in
    let* () = Pg.run conn t.s.set_paused (name, false, now) in
    Pg.run conn t.s.notify (t.name, name)
end

module Stats = struct
  type outcome = Completed | Retried | Discarded

  type t = {
    second : Ptime.t;
    queue : string;
    kind : string;
    outcome : outcome;
    count : int;
    run : Mtime.Span.t;
    wait : Mtime.Span.t;
  }

  let since conn at =
    let* rows = Pg.run conn the_table.s.stats at in
    Ok
      (List.map
         (fun (second, queue, kind, o, count, run_us, wait_us) ->
           {
             second;
             queue;
             kind;
             outcome =
               (match o with
               | Counted_completed -> Completed
               | Counted_retried -> Retried
               | Counted_discarded -> Discarded);
             count;
             run = span_of_us run_us;
             wait = span_of_us wait_us;
           })
         rows)
end

module Schedule = struct
  type t = {
    name : string;
    cron : Cron.t;
    kind : string;
    queue : string;
    payload : string;
    priority : int;
    max_attempts : int;
    partition : string option;
    sensitive : bool;
  }

  let make ~name ~cron ~zone ?priority (kind : _ Kind.t) payload =
    let refuse what =
      invalid_arg (Printf.sprintf "Spool.Schedule.make %S: %s" name what)
    in
    if String.length name = 0 then refuse "a schedule needs a name";
    let cron =
      match Cron.parse cron ~zone with Ok c -> c | Error why -> refuse why
    in
    (* A schedule that names no instant is a mistake in source, as the
       thirtieth of February is: asked from an instant past every zone's
       oddities, it would never run. *)
    (match Ptime.of_date (2001, 1, 1) with
    | Some from when Option.is_none (Cron.next cron ~after:from) ->
        refuse "it names no instant"
    | Some _ | None -> ());
    let priority = Option.value priority ~default:kind.priority in
    if priority < 0 || priority > 9 then refuse "a priority is 0 to 9";
    let payload_text =
      match Wiretype.encode kind.payload payload with
      | Ok text -> text
      | Error e ->
          refuse
            ("its payload cannot be written: " ^ Wiretype.Unwritable.to_string e)
    in
    {
      name;
      cron;
      kind = kind.name;
      queue = kind.queue;
      payload = payload_text;
      priority;
      max_attempts = kind.max_attempts;
      partition = Option.map (fun f -> f payload) kind.partition;
      sensitive = kind.sensitive;
    }

  let name t = t.name
  let next t ~after = Cron.next t.cron ~after

  type info = {
    name : string;
    cron : string;
    zone : string;
    kind : string;
    queue : string;
    next_at : Ptime.t;
    last_at : Ptime.t option;
  }

  let list conn =
    let* rows = Pg.run conn the_table.s.schedules () in
    Ok
      (List.map
         (fun (name, cron, zone, kind, queue, next_at, last_at) ->
           { name; cron; zone; kind; queue; next_at; last_at })
         rows)

  let run_now conn ~now name =
    let t = the_table in
    let* row = Pg.run conn t.s.enqueue_tick (name, now) in
    match row with
    | None -> Ok None
    | Some (id, queue) ->
        let* () = Pg.run conn t.s.notify (t.name, queue) in
        Ok (Some id)
end

(* A runner's queues as its row writes them, and the one reading of them. *)
let runner_queues_json =
  Wiretype.list
    (Wiretype.Object.map ~kind:"queue" (fun queue slots -> (queue, slots))
    |> Wiretype.Object.mem "queue" Wiretype.string ~enc:fst
    |> Wiretype.Object.mem "slots" Wiretype.int ~enc:snd
    |> Wiretype.Object.finish)

(* ------------------------------------------------------------------ *)
(* Running *)

type job = {
  id : Id.t;
  attempt : int;
  max_attempts : int;
  inserted_at : Ptime.t;
}

type failure =
  | Retry of string
  | Retry_in of Mtime.Span.t * string
  | Discard of string

type handler =
  | Handler : 'a Kind.t * (job -> 'a -> (unit, failure) result) -> handler

let handle kind f = Handler (kind, f)

module Runner = struct
  type refused =
    | Unrun_queue of string
    | Two_handlers of string
    | No_concurrency of string
    | Unreachable of Rowtype.error
    | Unmigrated of string list
    | Two_schedules of string

  type info = {
    id : string;
    host : string;
    pid : int;
    queues : (string * int) list;
    started_at : Ptime.t;
    seen_at : Ptime.t;
  }

  let list conn =
    let* rows = Pg.run conn the_table.s.runners () in
    let rec read acc = function
      | [] -> Ok (List.rev acc)
      | (id, host, pid, queues, started_at, seen_at) :: rest -> (
          match Wiretype.decode runner_queues_json queues with
          | Error problems ->
              Error
                (`Db
                   ("a runner's queues could not be read: "
                   ^ Wiretype.Problem.list_to_string problems))
          | Ok queues ->
              read ({ id; host; pid; queues; started_at; seen_at } :: acc) rest)
    in
    read [] rows

  let refused_to_string = function
    | Unrun_queue kind ->
        Printf.sprintf "the kind %S is in a queue this runner does not run" kind
    | Two_handlers kind -> Printf.sprintf "the kind %S is handled twice" kind
    | No_concurrency queue ->
        Printf.sprintf "the queue %S is given fewer than one slot" queue
    | Unreachable e ->
        "the runner's connections could not be made: " ^ S.error_to_string e
    | Two_schedules name -> Printf.sprintf "the schedule %S is given twice" name
    | Unmigrated problems ->
        Printf.sprintf
          "the table %s is missing or behind what spool runs (%s): apply \
           spool's migrations, as `rowtype-migrate up --source spool` does"
          table
          (String.concat "; " problems)

  (* The runner's pool, made only on a database whose table is what spool
     runs: found missing or behind at start, not by the first job. *)
  let checked_pool ~sw ~net ~mono_clock ~size ?observe conninfo =
    match Pg.Pool.create ~sw ~net ~mono_clock ~size ?observe conninfo with
    | Error e -> Error (Unreachable (e :> S.error))
    | Ok pool -> (
        let refused r =
          Pg.Pool.close pool;
          Error r
        in
        match Pg.Pool.use pool (fun conn -> Pg.verify conn statements) with
        | Ok (Ok ()) -> Ok pool
        | Ok (Error (`Disagreements problems)) -> refused (Unmigrated problems)
        | Ok (Error (#S.error as e)) -> refused (Unreachable e)
        | Error e -> refused (Unreachable (`Db (Pg.error_to_string e))))

  (* Why a running job's fiber was stopped, which decides what is written
     for it: a lease lost writes nothing, since the row is no longer this
     runner's; stopping puts it back, in one statement for all of them. *)
  type interrupted = Lost | Stopping

  exception Interrupt of interrupted

  type running = {
    queue : string;
    cc : Eio.Cancel.t;
    mutable renewed : Mtime.t;  (** when its lease was last renewed *)
  }

  type queue = {
    qname : string;
    slots : int;
    kinds : string list;  (** the kinds of it this runner handles *)
    mutable dirty : bool;  (** woken since it last looked *)
    cond : Eio.Condition.t;
  }

  (* Every fiber of a runner is on the switch it was made with, so on one
     domain, and Eio runs them one at a time between effects: the tables
     below are touched by no two at once, and need no lock. *)
  type t = {
    sw : Eio.Switch.t;
    net : [ `Generic ] Eio.Net.ty Eio.Resource.t;
    clock : Eio.Time.Mono.ty Eio.Resource.t;
    now : unit -> Ptime.t;
    table : table;
    runner : string;
    host : string;
    started_at : Ptime.t;
    pool : Pg.Pool.t;
    conninfo : Pg.Conninfo.t;
    poll : Mtime.Span.t;
    lease : Mtime.Span.t;
    retain_completed : Mtime.Span.t;
    retain_failed : Mtime.Span.t;
    queues : queue list;
    schedules : Schedule.t list;
    handlers : (string, handler) Hashtbl.t;
    running : (int, running) Hashtbl.t;
    mutable closing : bool;  (** claiming nothing more *)
    mutable closed : bool;
    idle : Eio.Condition.t;  (** a job ended *)
    quit : Eio.Condition.t;  (** stopping, to whoever sleeps *)
    mutable listener : Pg.Listener.t option;
    mutable pruned : Mtime.t option;
  }

  let mono t = Eio.Time.Mono.now t.clock
  let since t at = Mtime.span at (mono t)
  let words = Pg.error_to_string

  (* One short transaction on the runner's own pool. *)
  let use t f =
    match Pg.Pool.use t.pool (fun conn -> Pg.Transaction.within conn f) with
    | Ok r -> r
    | Error (`Pool p) -> Error (`Pool p)

  let wake (q : queue) =
    q.dirty <- true;
    Eio.Condition.broadcast q.cond

  (* A sleep that stopping ends early, so no fiber of a stopped runner
     outlives it by a poll. *)
  let sleep t span =
    if not t.closed then
      ignore
        (Eio.Time.Timeout.run (Eio.Time.Timeout.v t.clock span) (fun () ->
             Eio.Condition.await_no_mutex t.quit;
             Ok ()))

  let create ~sw ~net ~mono_clock ~now ?(pool_size = 2) ?(poll = Mtime.Span.s)
      ?(lease = Mtime.Span.min) ?(retain_completed = Mtime.Span.day)
      ?(retain_failed = Mtime.Span.(14 * day)) ?observe ?(schedules = [])
      ~queues handlers conninfo =
    let by_kind = Hashtbl.create 8 in
    let refused =
      List.find_map
        (fun (Handler (kind, _) as h) ->
          if Hashtbl.mem by_kind kind.Kind.name then
            Some (Two_handlers kind.name)
          else (
            Hashtbl.replace by_kind kind.name h;
            if List.exists (fun (q, _) -> String.equal q kind.queue) queues then
              None
            else Some (Unrun_queue kind.name)))
        handlers
    in
    let refused =
      match refused with
      | Some _ -> refused
      | None ->
          List.find_map
            (fun (q, n) -> if n < 1 then Some (No_concurrency q) else None)
            queues
    in
    let refused =
      match refused with
      | Some _ -> refused
      | None ->
          let rec twice seen = function
            | [] -> None
            | (sc : Schedule.t) :: rest ->
                if List.mem sc.name seen then Some (Two_schedules sc.name)
                else twice (sc.name :: seen) rest
          in
          twice [] schedules
    in
    match refused with
    | Some r -> Error r
    | None -> (
        let named pool =
          let at = now () in
          let hold conn (sc : Schedule.t) =
            match Cron.next sc.cron ~after:at with
            | None -> Ok ()
            | Some next_at ->
                Pg.run conn the_table.s.hold_schedule
                  ( sc.name,
                    Cron.expression sc.cron,
                    Cron.zone sc.cron,
                    sc.kind,
                    sc.queue,
                    sc.payload,
                    sc.priority,
                    sc.max_attempts,
                    sc.partition,
                    next_at,
                    sc.sensitive )
          in
          match
            Pg.Pool.use pool (fun conn ->
                Pg.Transaction.within conn (fun conn ->
                    let* () =
                      Pg.run conn the_table.s.name_queues
                        (List.map fst queues, at)
                    in
                    List.fold_left
                      (fun acc sc -> Result.bind acc (fun () -> hold conn sc))
                      (Ok ()) schedules))
          with
          | Ok (Ok ()) -> Ok pool
          | Ok (Error (#S.error as e)) ->
              Pg.Pool.close pool;
              Error (Unreachable e)
          | Ok (Error (`Not_committed m)) ->
              Pg.Pool.close pool;
              Error (Unreachable (`Db m))
          | Error e ->
              Pg.Pool.close pool;
              Error (Unreachable (`Db (Pg.error_to_string e)))
        in
        match
          Result.bind
            (checked_pool ~sw ~net ~mono_clock ~size:pool_size ?observe conninfo)
            named
        with
        | Error r -> Error r
        | Ok pool ->
            let queue (qname, slots) =
              {
                qname;
                slots;
                kinds =
                  List.filter_map
                    (fun (Handler (k, _)) ->
                      if String.equal k.Kind.queue qname then Some k.name
                      else None)
                    handlers;
                dirty = false;
                cond = Eio.Condition.create ();
              }
            in
            Ok
              {
                sw;
                net :> [ `Generic ] Eio.Net.ty Eio.Resource.t;
                clock = (mono_clock :> Eio.Time.Mono.ty Eio.Resource.t);
                now;
                table = the_table;
                (* Which runner holds a lease, unique enough among the
                   runners that share a table: a host, a process and a
                   draw. *)
                runner =
                  Printf.sprintf "%s/%d/%06x" (Unix.gethostname ())
                    (Unix.getpid ())
                    (Random.bits () land 0xffffff);
                host = Unix.gethostname ();
                started_at = now ();
                pool;
                conninfo;
                poll;
                lease;
                retain_completed;
                retain_failed;
                queues = List.map queue queues;
                schedules;
                handlers = by_kind;
                running = Hashtbl.create 16;
                closing = false;
                closed = false;
                idle = Eio.Condition.create ();
                quit = Eio.Condition.create ();
                listener = None;
                pruned = None;
              })

  (* ---------------------------------------------------------------- *)
  (* One attempt *)

  type outcome = Done | Failed of failure | Interrupted of interrupted

  let outcome_words = function
    | Done -> "completed"
    | Failed (Retry r) -> "failed, to be retried: " ^ r
    | Failed (Retry_in (after, r)) ->
        Format.asprintf "failed, to be retried in %a: %s" Mtime.Span.pp after r
    | Failed (Discard r) -> "discarded: " ^ r
    | Interrupted Lost -> "stopped: its lease was lost"
    | Interrupted Stopping -> "interrupted by the runner stopping"

  (* The handler, bounded by its kind's timeout, its raise a retry. Run on
     the calling fiber: a runner's own, or the test's in [drain]. *)
  let run_attempt t (Handler (kind, f))
      ((id, _, payload, attempt, max_attempts, inserted_at) : claimed) =
    match Wiretype.decode kind.payload payload with
    | Error problems ->
        Failed
          (Discard
             ("its payload no longer decodes: "
             ^ Wiretype.Problem.list_to_string problems))
    | Ok a -> (
        let job = { id; attempt; max_attempts; inserted_at } in
        match
          Eio.Time.Timeout.run (Eio.Time.Timeout.v t.clock kind.timeout)
            (fun () ->
              match f job a with
              | Ok () -> Ok Done
              | Error failure -> Ok (Failed failure))
        with
        | Ok o -> o
        | Error `Timeout ->
            Failed
              (Retry
                 (Format.asprintf "timed out after %a" Mtime.Span.pp
                    kind.timeout))
        | exception Eio.Cancel.Cancelled (Interrupt why) -> Interrupted why
        | exception (Eio.Cancel.Cancelled _ as e) -> raise e
        | exception e ->
            (* The reason names the constructor and never its text, which
               may carry an argument; the line carries all of it. *)
            let bt = Printexc.get_raw_backtrace () in
            Log.err (fun m ->
                m "%s job %d attempt %d raised %s\n%s" kind.name id attempt
                  (Printexc.to_string e)
                  (Printexc.raw_backtrace_to_string bt));
            Failed (Retry (Printexc.exn_slot_name e ^ " raised")))

  (* What the attempt came to, written by one statement guarded by the
     claim, and the state it left the job in; [None] where nothing was
     written. *)
  let finish t (Handler (kind, _)) ~id ~attempt ~max_attempts ~took outcome =
    let now = t.now () in
    let s = t.table.s in
    let run_us = Int64.unsigned_div (Mtime.Span.to_uint64_ns took) 1000L in
    (* The attempt counted and its row written in one transaction, so the
       statistics say what the table does. *)
    (* What waits on the job learns how it ended in the transaction that
       records it, so no dependent is left blocked on a job that ended. *)
    let after_written c counted n =
      if n = 0 then Ok n
      else
        let* () =
          match counted with
          | Counted_completed -> release_dependents c id
          | Counted_discarded -> doom c ~now id "was discarded"
          | Counted_retried -> Ok ()
        in
        Ok n
    in
    let write counted st args =
      use t (fun c ->
          let* () =
            Pg.run c s.count_attempt
              (id, t.runner, attempt, now, counted, run_us)
          in
          let* n = Pg.run c st args in
          after_written c counted n)
    in
    let written =
      match outcome with
      | Interrupted _ -> None
      | Done ->
          Some
            ( (if kind.keep then
                 write Counted_completed s.complete (id, t.runner, attempt, now)
               else
                 use t (fun c ->
                     let* () =
                       Pg.run c s.count_attempt
                         (id, t.runner, attempt, now, Counted_completed, run_us)
                     in
                     let* n =
                       Pg.run c s.delete_done (id, t.runner, attempt, now)
                     in
                     let* n =
                       if n > 0 then Ok n
                       else
                         Pg.run c s.complete_emptied (id, t.runner, attempt, now)
                     in
                     after_written c Counted_completed n)),
              Completed )
      | Failed (Discard reason) ->
          Some
            ( write Counted_discarded s.discard
                (id, t.runner, attempt, now, now, reason),
              Discarded )
      | Failed (Retry reason | Retry_in (_, reason))
        when attempt >= max_attempts ->
          Some
            ( write Counted_discarded s.give_up
                (id, t.runner, attempt, now, now, reason),
              Discarded )
      | Failed (Retry reason) ->
          Some
            ( write Counted_retried s.again
                ( id,
                  t.runner,
                  attempt,
                  later now (kind.backoff ~attempt),
                  now,
                  reason ),
              Available )
      | Failed (Retry_in (delay, reason)) ->
          Some
            ( write Counted_retried s.again
                (id, t.runner, attempt, later now delay, now, reason),
              Available )
    in
    let said () =
      Format.asprintf "%s job %d attempt %d %s in %a" kind.name id attempt
        (outcome_words outcome) Mtime.Span.pp took
    in
    match written with
    | None ->
        Log.info (fun m -> m "%s" (said ()));
        None
    | Some (Ok 1, state) ->
        (match state with
        | Completed -> Log.info (fun m -> m "%s" (said ()))
        | Available -> Log.warn (fun m -> m "%s" (said ()))
        | Discarded | Blocked | Running | Cancelled ->
            Log.err (fun m -> m "%s" (said ())));
        Some state
    | Some (Ok _, _) ->
        Log.info (fun m ->
            m "%s; its lease was taken or the job cancelled, so nothing changed"
              (said ()));
        None
    | Some (Error e, _) ->
        Log.warn (fun m -> m "%s, and not recorded: %s" (said ()) (words e));
        None

  let handler_of t kind = Hashtbl.find_opt t.handlers kind

  (* ---------------------------------------------------------------- *)
  (* The fibers *)

  (* A queue with no limit, no rate and no partitions is claimed from as
     it always was, taking no lock; a limited one under the queue's lock,
     counting what runs and what began in the rate's period. *)
  let claim t (q : queue) ~free =
    let now = t.now () in
    let s = t.table.s in
    use t (fun c ->
        let plain () =
          Pg.run c s.claim
            (t.runner, now, later now t.lease, q.qname, q.kinds, free)
        in
        let* settings = Pg.run c s.settings q.qname in
        match settings with
        | None | Some (false, None, None, _, false) -> plain ()
        | Some (true, _, _, _, _) -> Ok []
        | Some (false, running, attempts, per_us, per_partition) ->
            let* () = Pg.run c s.lock_queue q.qname in
            let since =
              earlier now (span_of_us (Option.value per_us ~default:0L))
            in
            let* () = Pg.run c s.forget_starts (q.qname, since) in
            Pg.run c s.claim_limited
              ( t.runner,
                now,
                later now t.lease,
                q.qname,
                q.kinds,
                free,
                running,
                attempts,
                since,
                per_partition ))

  let run_claimed t (q : queue) ((id, kind, _, attempt, max_attempts, _) as row)
      =
    match handler_of t kind with
    | None -> ()
    | Some h ->
        Eio.Fiber.fork ~sw:t.sw (fun () ->
            let started = mono t in
            (try
               Eio.Cancel.sub (fun cc ->
                   Hashtbl.replace t.running id
                     { queue = q.qname; cc; renewed = started };
                   let outcome = run_attempt t h row in
                   Hashtbl.remove t.running id;
                   let took = since t started in
                   ignore (finish t h ~id ~attempt ~max_attempts ~took outcome))
             with
            | Eio.Cancel.Cancelled _ -> Hashtbl.remove t.running id
            | e ->
                Hashtbl.remove t.running id;
                Log.err (fun m ->
                    m "job %d's fiber failed: %s" id (Printexc.to_string e)));
            wake q;
            Eio.Condition.broadcast t.idle)

  (* Leases lapsed, their jobs put back or, on their last attempt,
     discarded, and what waits on those cancelled; expired jobs the same. *)
  let rescue c ~now =
    let* rows = Pg.run c the_table.s.rescue now in
    let* () =
      List.fold_left
        (fun acc (id, (st : state)) ->
          let* () = acc in
          match st with
          | Discarded -> doom c ~now id "was discarded"
          | Available | Blocked | Running | Completed | Cancelled -> Ok ())
        (Ok ()) rows
    in
    Ok rows

  let expire c ~now =
    let* ids = Pg.run c the_table.s.expire now in
    let* () =
      List.fold_left
        (fun acc id ->
          let* () = acc in
          doom c ~now id "expired")
        (Ok ()) ids
    in
    Ok ids

  (* Every schedule this runner holds whose tick has come: the latest tick
     due enqueued, and the next moved past now, in one transaction guarded by
     the next tick it read, so of every runner that reads it, one enqueues
     it. Ticks missed while nothing ran are the latest alone. *)
  let fire t =
    let now = t.now () in
    let s = t.table.s in
    let by_name =
      List.map (fun (sc : Schedule.t) -> (sc.name, sc)) t.schedules
    in
    let* due = use t (fun c -> Pg.run c s.next_ticks (List.map fst by_name)) in
    let rec latest (sc : Schedule.t) tick =
      match Cron.next sc.cron ~after:tick with
      | Some after when not (Ptime.is_later after ~than:now) -> latest sc after
      | next -> (tick, next)
    in
    List.iter
      (fun (name, next_at) ->
        match List.assoc_opt name by_name with
        | Some sc when not (Ptime.is_later next_at ~than:now) -> (
            match latest sc next_at with
            | _, None -> ()
            | tick, Some following -> (
                match
                  use t (fun c ->
                      let* n =
                        Pg.run c s.advance (name, next_at, following, tick)
                      in
                      if n = 0 then Ok None
                      else
                        let* row = Pg.run c s.enqueue_tick (name, tick) in
                        match row with
                        | None -> Ok None
                        | Some (_, queue) ->
                            let* () = Pg.run c s.notify (t.table.name, queue) in
                            Ok (Some queue))
                with
                | Ok (Some queue) ->
                    Log.info (fun m ->
                        m "schedule %s: its tick of %s enqueued in %s" name
                          (Ptime.to_rfc3339 tick) queue)
                | Ok None -> ()
                | Error e ->
                    Log.warn (fun m ->
                        m "schedule %s: enqueueing its tick failed: %s" name
                          (words e))))
        | Some _ | None -> ())
      due;
    Ok
      (List.fold_left
         (fun soonest (_, at) ->
           match soonest with
           | Some s when Ptime.is_earlier s ~than:at -> soonest
           | Some _ | None -> Some at)
         None due)

  let busy t (q : queue) =
    Hashtbl.fold
      (fun _ (r : running) n ->
        if String.equal r.queue q.qname then n + 1 else n)
      t.running 0

  (* A queue's loop: claim what its free slots allow, then sleep until the
     next poll, a notification, a job of its ending, or the soonest
     scheduled job, whichever is first. The poll is the truth and a
     notification a hint. *)
  let rec queue_loop t (q : queue) =
    if not t.closing then begin
      let free = q.slots - busy t q in
      let wait =
        if free <= 0 then t.poll
        else
          match claim t q ~free with
          | Error e ->
              Log.warn (fun m ->
                  m "queue %s: claiming failed: %s" q.qname (words e));
              t.poll
          | Ok rows -> (
              List.iter (run_claimed t q) rows;
              if List.length rows >= free then t.poll
              else
                let now = t.now () in
                match
                  use t (fun c -> Pg.run c t.table.s.soonest (q.qname, now))
                with
                | Ok (Some at) -> shorter t.poll (until ~now at)
                | Ok None | Error _ -> t.poll)
      in
      if q.dirty then q.dirty <- false
      else (
        ignore
          (Eio.Time.Timeout.run (Eio.Time.Timeout.v t.clock wait) (fun () ->
               Eio.Condition.await_no_mutex q.cond;
               Ok ()));
        q.dirty <- false);
      queue_loop t q
    end

  let lost t id (r : running) why =
    Hashtbl.remove t.running id;
    Eio.Cancel.cancel r.cc (Interrupt why)

  (* A job whose lease has not been renewed for three quarters of it is
     stopped by the runner itself, before anybody else may claim it. Its own
     fiber, asking the database nothing, because the renewal it waits on is
     exactly what may hang. *)
  let watch t =
    let stale =
      Hashtbl.fold
        (fun id (r : running) acc ->
          if
            Mtime.Span.is_longer (since t r.renewed)
              ~than:Mtime.Span.(3 * part t.lease 4)
          then (id, r) :: acc
          else acc)
        t.running []
    in
    List.iter
      (fun (id, r) ->
        Log.warn (fun m ->
            m "job %d: its lease could not be renewed, stopped" id);
        lost t id r Lost)
      stale

  (* Every lease this runner holds renewed in one statement; a running job
     missing from the answer was cancelled or taken, and is stopped. Then
     every runner's housekeeping: lapsed leases rescued, expired jobs
     discarded, and once an hour the finished pruned. *)
  let beat t =
    let s = t.table.s in
    let held = Hashtbl.fold (fun id _ acc -> id :: acc) t.running [] in
    (if held <> [] then
       let now = t.now () in
       match
         use t (fun c -> Pg.run c s.renew (t.runner, later now t.lease, held))
       with
       | Ok renewed ->
           let at = mono t in
           List.iter
             (fun id ->
               match Hashtbl.find_opt t.running id with
               | Some r -> r.renewed <- at
               | None -> ())
             renewed;
           List.iter
             (fun id ->
               if not (List.mem id renewed) then
                 match Hashtbl.find_opt t.running id with
                 | Some r ->
                     Log.warn (fun m ->
                         m "job %d: its lease was taken or it was cancelled" id);
                     lost t id r Lost
                 | None -> ())
             held
       | Error e -> Log.warn (fun m -> m "renewing leases failed: %s" (words e)));
    let now = t.now () in
    let queues =
      Wiretype.encode runner_queues_json
        (List.map (fun (q : queue) -> (q.qname, q.slots)) t.queues)
    in
    (match queues with
    | Error _ -> ()
    | Ok queues -> (
        match
          use t (fun c ->
              let* () =
                Pg.run c s.seen
                  (t.runner, t.host, Unix.getpid (), queues, t.started_at, now)
              in
              Pg.run c s.forget_lapsed (earlier now t.lease))
        with
        | Ok () -> ()
        | Error e ->
            Log.warn (fun m -> m "recording the runner failed: %s" (words e))));
    (match use t (fun c -> rescue c ~now) with
    | Ok [] -> ()
    | Ok rows ->
        Log.warn (fun m ->
            m "%d jobs rescued from lapsed leases" (List.length rows))
    | Error e -> Log.warn (fun m -> m "rescuing failed: %s" (words e)));
    (match use t (fun c -> expire c ~now) with
    | Ok [] -> ()
    | Ok ids -> Log.err (fun m -> m "%d jobs expired unrun" (List.length ids))
    | Error e -> Log.warn (fun m -> m "expiring failed: %s" (words e)));
    let due =
      match t.pruned with
      | None -> true
      | Some at ->
          not (Mtime.Span.is_shorter (since t at) ~than:Mtime.Span.hour)
    in
    if due then
      match
        use t (fun c ->
            let* () = Pg.run c s.prune_stats (earlier now t.retain_completed) in
            let* () =
              Pg.run c s.prune_partitions (earlier now t.retain_completed)
            in
            Pg.run c s.prune
              (earlier now t.retain_completed, earlier now t.retain_failed, now))
      with
      | Ok n ->
          t.pruned <- Some (mono t);
          if n > 0 then Log.info (fun m -> m "%d finished jobs pruned" n)
      | Error e -> Log.warn (fun m -> m "pruning failed: %s" (words e))

  (* Every iteration of a loop is guarded, so one failure is a line and the
     loop goes on; a cancellation is the switch's, and passes. *)
  let guarded what f =
    try f () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Log.err (fun m -> m "%s: %s" what (Printexc.to_string e))

  let rec heartbeat t =
    if not t.closed then begin
      guarded "the heartbeat" (fun () -> beat t);
      sleep t (part t.lease 4);
      heartbeat t
    end

  let rec watchdog t =
    if not t.closed then begin
      guarded "the watchdog" (fun () -> watch t);
      sleep t (part t.lease 16);
      watchdog t
    end

  (* Ticks are checked every poll, and as soon as the soonest one is due;
     the poll is what makes a schedule another runner changed seen. *)
  let rec scheduler t =
    if not t.closing then begin
      let wait =
        match fire t with
        | Ok (Some at) -> shorter t.poll (until ~now:(t.now ()) at)
        | Ok None -> t.poll
        | Error e ->
            Log.warn (fun m -> m "checking schedules failed: %s" (words e));
            t.poll
      in
      sleep t wait;
      scheduler t
    end

  let wake_all t = List.iter wake t.queues

  (* Notifications route a queue's name to its loop. A listener lost is
     made again; while it is, the poll is all there is, and a job waits a
     poll at most. *)
  let rec listen t delay =
    if not t.closing then
      match
        Pg.Listener.connect ~sw:t.sw ~net:t.net ~mono_clock:t.clock t.conninfo
      with
      | Error e ->
          Log.warn (fun m -> m "the listener could not connect: %s" (words e));
          sleep t delay;
          listen t (shorter Mtime.Span.(30 * s) Mtime.Span.(2 * delay))
      | Ok l -> (
          match Pg.Listener.listen l t.table.name with
          | Error e ->
              Log.warn (fun m ->
                  m "the listener could not listen: %s" (words e));
              Pg.Listener.close l;
              sleep t delay;
              listen t (shorter Mtime.Span.(30 * s) Mtime.Span.(2 * delay))
          | Ok () ->
              t.listener <- Some l;
              wake_all t;
              hear t l)

  and hear t l =
    match Pg.Listener.next l with
    | Ok (Pg.Listener.Notification { payload; _ }) ->
        List.iter
          (fun (q : queue) -> if String.equal q.qname payload then wake q)
          t.queues;
        hear t l
    | Ok Pg.Listener.Reconnected ->
        wake_all t;
        hear t l
    | Error e ->
        t.listener <- None;
        Pg.Listener.close l;
        if not t.closing then (
          Log.warn (fun m -> m "the listener was lost: %s" (words e));
          sleep t Mtime.Span.s;
          listen t Mtime.Span.s)

  let start t =
    let daemon what f =
      Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
          guarded what f;
          `Stop_daemon)
    in
    List.iter
      (fun (q : queue) ->
        daemon ("queue " ^ q.qname) (fun () -> queue_loop t q))
      t.queues;
    daemon "the heartbeat" (fun () -> heartbeat t);
    daemon "the watchdog" (fun () -> watchdog t);
    (match t.schedules with
    | [] -> ()
    | _ :: _ -> daemon "the scheduler" (fun () -> scheduler t));
    daemon "the listener" (fun () -> listen t Mtime.Span.s)

  (* ---------------------------------------------------------------- *)
  (* A test's, and stopping *)

  let drain t =
    let outcomes = ref [] in
    let rec go () =
      let now = t.now () in
      let* _ = use t (fun c -> rescue c ~now) in
      let* _ = match t.schedules with [] -> Ok None | _ :: _ -> fire t in
      let* expired = use t (fun c -> expire c ~now) in
      outcomes := List.rev_map (fun id -> (id, Discarded)) expired @ !outcomes;
      let rec first = function
        | [] -> Ok false
        | (q : queue) :: rest -> (
            let* rows = claim t q ~free:1 in
            match rows with
            | [] -> first rest
            | ((id, kind, _, attempt, max_attempts, _) as row) :: _ -> (
                match handler_of t kind with
                | None -> first rest
                | Some h ->
                    let started = mono t in
                    let outcome = run_attempt t h row in
                    let took = since t started in
                    (match
                       finish t h ~id ~attempt ~max_attempts ~took outcome
                     with
                    | Some state -> outcomes := (id, state) :: !outcomes
                    | None -> ());
                    Ok true))
      in
      let* ran = first t.queues in
      if ran then go () else Ok (List.rev !outcomes)
    in
    Result.map_error words (go ())

  let stop ?(grace = Mtime.Span.(10 * s)) t =
    if not t.closing then begin
      t.closing <- true;
      wake_all t;
      ignore
        (Eio.Time.Timeout.run (Eio.Time.Timeout.v t.clock grace) (fun () ->
             while Hashtbl.length t.running > 0 do
               Eio.Condition.await_no_mutex t.idle
             done;
             Ok ()));
      let left = Hashtbl.fold (fun id r acc -> (id, r) :: acc) t.running [] in
      List.iter (fun (id, r) -> lost t id r Stopping) left;
      Eio.Fiber.yield ();
      (if left <> [] then
         let ids = List.map fst left in
         match
           use t (fun c ->
               Pg.run c t.table.s.put_back (t.runner, t.now (), ids))
         with
         | Ok n -> Log.info (fun m -> m "%d interrupted jobs put back" n)
         | Error e ->
             Log.warn (fun m ->
                 m
                   "putting back interrupted jobs failed, so their leases will \
                    lapse: %s"
                   (words e)));
      (match use t (fun c -> Pg.run c t.table.s.forget_runner t.runner) with
      | Ok () -> ()
      | Error e ->
          Log.warn (fun m ->
              m "removing the runner's row failed, so it lapses: %s" (words e)));
      t.closed <- true;
      Eio.Condition.broadcast t.quit;
      Option.iter Pg.Listener.close t.listener;
      Pg.Pool.close t.pool
    end
end
