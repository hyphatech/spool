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

type state = Available | Running | Completed | Discarded | Cancelled

let state_to_string = function
  | Available -> "available"
  | Running -> "running"
  | Completed -> "completed"
  | Discarded -> "discarded"
  | Cancelled -> "cancelled"

let state_of_string = function
  | "available" -> Some Available
  | "running" -> Some Running
  | "completed" -> Some Completed
  | "discarded" -> Some Discarded
  | "cancelled" -> Some Cancelled
  | _ -> None

let state_ty = S.parse S.text ~of_:state_of_string ~to_:state_to_string

type failed = { attempt : int; at : Ptime.t; reason : string }

(* A failed attempt's instant as the errors column writes it, whole epoch
   milliseconds, which an operator reads in the row: the statements that
   append one write it so, and this is the one reading of it. *)
let at_json =
  let ms_ps = 1_000_000_000L and day_ms = 86_400_000 in
  Wiretype.kind ~name:"epoch milliseconds"
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
    ( string
      * string
      * string
      * int
      * int
      * Ptime.t
      * Ptime.t option
      * string option
      * Ptime.t,
      int )
    S.statement;
  notify : (string * string, unit) S.statement;
  find :
    ( int,
      (int
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
      option )
    S.statement;
  counts : (unit, (string * state * int) list) S.statement;
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
  delete_done : (int * string * int, int) S.statement;
  again : (int * string * int * Ptime.t * Ptime.t * string, int) S.statement;
  give_up : (int * string * int * Ptime.t * Ptime.t * string, int) S.statement;
  discard : (int * string * int * Ptime.t * Ptime.t * string, int) S.statement;
  put_back : (string * Ptime.t * int list, int) S.statement;
  rescue : (Ptime.t, int) S.statement;
  expire : (Ptime.t, int list) S.statement;
  prune : (Ptime.t * Ptime.t, int) S.statement;
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
          S.(t9 text text text int int instant (opt instant) (opt text) instant)
        ~row:S.int
        (q
           {|insert into {t} (queue, kind, payload, priority, state, attempt,
     max_attempts, scheduled_at, expires_at, unique_key, inserted_at, errors)
   values ($1, $2, $3::jsonb, $4, 'available', 0, $5, $6, $7, $8, $9, '[]')
   on conflict (kind, unique_key)
     where state = 'available' and unique_key is not null
   do update set scheduled_at = least({t}.scheduled_at, excluded.scheduled_at),
                 priority = least({t}.priority, excluded.priority)
   returning id|});
    notify = S.exec ~params:S.(t2 text text) "select pg_notify($1, $2)";
    find =
      S.find_opt ~params:S.int
        ~row:
          S.(
            t11 int text text state_ty int int int instant instant (opt instant)
              text)
        (q
           {|select id, queue, kind, state, priority, attempt, max_attempts,
     scheduled_at, inserted_at, finished_at, errors::text
   from {t} where id = $1|});
    counts =
      S.list ~params:S.unit
        ~row:S.(t3 text state_ty int)
        (q
           {|select queue, state, count(*)::integer from {t}
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
           {|update {t} set state = 'available', attempt = 0, scheduled_at = $2,
     finished_at = null
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
    delete_done =
      S.exec_count
        ~params:S.(t3 int text int)
        (q ("delete from {t} where " ^ held));
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
      S.exec_count ~params:S.instant
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
   where state = 'running' and lease_ends_at < $1|}
           ));
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
        ~params:S.(t2 instant instant)
        (q
           {|delete from {t}
   where (state = 'completed' and finished_at < $1)
      or (state in ('discarded', 'cancelled') and finished_at < $2)|});
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
      Any s.notify;
      Any s.find;
      Any s.counts;
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
    ]

(* ------------------------------------------------------------------ *)
(* Kinds *)

module Id = struct
  type t = int

  let equal = Int.equal
  let to_string = string_of_int
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
      ?(timeout = Mtime.Span.(5 * min)) ?(backoff = backoff) ?(keep = true) name
      payload =
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
    { name; queue; priority; max_attempts; timeout; backoff; keep; payload }

  let name k = k.name
end

(* ------------------------------------------------------------------ *)
(* Enqueueing, and an operator's hand *)

let enqueue ?at ?after ?priority ?unique ?expires_at conn ~now (kind : _ Kind.t)
    payload =
  let t = the_table in
  let priority = Option.value priority ~default:kind.priority in
  if priority < 0 || priority > 9 then Error (`Bad_priority priority)
  else
    let* text =
      Result.map_error
        (fun m -> `Unencodable m)
        (Wiretype.encode kind.payload payload)
    in
    let scheduled_at =
      match (at, after) with
      | Some at, _ -> at
      | None, Some span -> later now span
      | None, None -> now
    in
    let* id =
      Pg.run conn t.s.insert
        ( kind.queue,
          kind.name,
          text,
          priority,
          kind.max_attempts,
          scheduled_at,
          expires_at,
          unique,
          now )
    in
    (* Heard when the caller's transaction commits, and never if it rolls
       back: a hint, which a runner's poll makes good. *)
    let* () = Pg.run conn t.s.notify (t.name, kind.queue) in
    Ok id

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
}

let find conn id =
  let* row = Pg.run conn the_table.s.find id in
  match row with
  | None -> Ok None
  | Some
      ( id,
        queue,
        kind,
        state,
        priority,
        attempt,
        max_attempts,
        scheduled_at,
        inserted_at,
        finished_at,
        errors ) -> (
      match Wiretype.decode errors_json errors with
      | Error problems ->
          Error
            (`Db
               ("a job's errors could not be read: "
               ^ Wiretype.Problem.list_to_string problems))
      | Ok errors ->
          Ok
            (Some
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
               }))

let counts conn = Pg.run conn the_table.s.counts ()

let cancel conn ~now id =
  let* n = Pg.run conn the_table.s.cancel (id, now) in
  Ok (n > 0)

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

  let refused_to_string = function
    | Unrun_queue kind ->
        Printf.sprintf "the kind %S is in a queue this runner does not run" kind
    | Two_handlers kind -> Printf.sprintf "the kind %S is handled twice" kind
    | No_concurrency queue ->
        Printf.sprintf "the queue %S is given fewer than one slot" queue
    | Unreachable e ->
        "the runner's connections could not be made: " ^ S.error_to_string e
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
        | Error e -> refused (Unreachable (`Db (Pg.Pool.error_to_string e))))

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
    pool : Pg.Pool.t;
    conninfo : Pg.Conninfo.t;
    poll : Mtime.Span.t;
    lease : Mtime.Span.t;
    retain_completed : Mtime.Span.t;
    retain_failed : Mtime.Span.t;
    queues : queue list;
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

  let words = function
    | `Pool `Busy -> "no connection came free within the pool's wait"
    | `Pool `Closed -> "the pool is closed"
    | `Not_committed m -> "not committed: " ^ m
    | #S.error as e -> S.error_to_string e

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
      ?(retain_failed = Mtime.Span.(14 * day)) ?observe ~queues handlers
      conninfo =
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
    match refused with
    | Some r -> Error r
    | None -> (
        match
          checked_pool ~sw ~net ~mono_clock ~size:pool_size ?observe conninfo
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
                pool;
                conninfo;
                poll;
                lease;
                retain_completed;
                retain_failed;
                queues = List.map queue queues;
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
    let write st args = use t (fun c -> Pg.run c st args) in
    let written =
      match outcome with
      | Interrupted _ -> None
      | Done ->
          Some
            ( (if kind.keep then write s.complete (id, t.runner, attempt, now)
               else write s.delete_done (id, t.runner, attempt)),
              Completed )
      | Failed (Discard reason) ->
          Some
            ( write s.discard (id, t.runner, attempt, now, now, reason),
              Discarded )
      | Failed (Retry reason | Retry_in (_, reason))
        when attempt >= max_attempts ->
          Some
            ( write s.give_up (id, t.runner, attempt, now, now, reason),
              Discarded )
      | Failed (Retry reason) ->
          Some
            ( write s.again
                ( id,
                  t.runner,
                  attempt,
                  later now (kind.backoff ~attempt),
                  now,
                  reason ),
              Available )
      | Failed (Retry_in (delay, reason)) ->
          Some
            ( write s.again (id, t.runner, attempt, later now delay, now, reason),
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
        | Discarded | Running | Cancelled -> Log.err (fun m -> m "%s" (said ())));
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

  let claim t (q : queue) ~free =
    let now = t.now () in
    use t (fun c ->
        Pg.run c t.table.s.claim
          (t.runner, now, later now t.lease, q.qname, q.kinds, free))

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
    (match use t (fun c -> Pg.run c s.rescue now) with
    | Ok 0 -> ()
    | Ok n -> Log.warn (fun m -> m "%d jobs rescued from lapsed leases" n)
    | Error e -> Log.warn (fun m -> m "rescuing failed: %s" (words e)));
    (match use t (fun c -> Pg.run c s.expire now) with
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
            Pg.run c s.prune
              (earlier now t.retain_completed, earlier now t.retain_failed))
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
    daemon "the listener" (fun () -> listen t Mtime.Span.s)

  (* ---------------------------------------------------------------- *)
  (* A test's, and stopping *)

  let drain t =
    let s = t.table.s in
    let outcomes = ref [] in
    let rec go () =
      let now = t.now () in
      let* _ = use t (fun c -> Pg.run c s.rescue now) in
      let* expired = use t (fun c -> Pg.run c s.expire now) in
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
      t.closed <- true;
      Eio.Condition.broadcast t.quit;
      Option.iter Pg.Listener.close t.listener;
      Pg.Pool.close t.pool
    end
end
