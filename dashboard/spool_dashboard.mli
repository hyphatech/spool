(** A live dashboard for spool's queue, as routes of the application's own
    Spindle server.

    {[
    let db : Spindle_postgres.Pool.t Spindle.Dep.t =
      Spindle.Dep.of_resource "database"

    let operator = Spindle.Access.principal ~id:Auth.user_id Auth.signed_in

    let may (user : Auth.user) (action : Spool_dashboard.action) :
        Spindle.Access.decision =
      match (user.role, action) with
      | (Support | Admin), View | Admin, _ -> Allow
      | Support, _ -> Deny "support only looks"
      | Customer, _ -> Deny "not an operator"

    let routes =
      Routes.routes
      @ Spool_dashboard.routes ~operator ~may ~pool:db ~mono_clock ()
    ]}

    The page at [/spool] shows, live, what waits, is blocked and runs in each
    queue, the runners, the queues and their limits, the schedules, and a chart
    of the attempts of the last minutes; it lists jobs by state, queue and kind,
    shows one's attempts, payload and workflow, and cancels, retries and deletes
    a job or a selection, pauses and resumes a queue and sets its limits, and
    runs a schedule now.

    {b Who may do what is the application's to say}, and there is no default:
    the dashboard cancels and deletes, and an open default is how it ends up
    public. [operator] is who calls, as the application knows them -- its own
    user, read from a session or a token -- and [may] decides each {!action} for
    them, reading what the application keeps: a role, a flag, a scope. Every
    route asks it through [Spindle.Access] before anything else, so nobody
    signed in is a [401], an action [may] denies a [403], and each denial a line
    on Spindle's [spindle.access] source naming the caller and the reason.
    [Spindle.Access.unguarded] lists none of these routes. The page shows only
    what its viewer may do.

    Whatever it does, it does through spool's own functions -- {!Spool.cancel},
    {!Spool.Queue.pause}, {!Spool.Schedule.run_now} -- so it can do nothing code
    cannot; and each action is a line on the [spool-dashboard] source, at
    [Info], saying what it was done to, in the request the caller is recorded
    on. A kind made [~sensitive] shows no payload, as spool answers none.

    The page is built in: its files are compiled into the library and served
    from memory, the hashed ones kept a year by the browser and the page asked
    for again each time, so nothing is fetched or built where it runs. It calls
    its routes relative to where it is served, so it works under any prefix a
    proxy puts it behind. *)

(** What an operator may be allowed to do. A constructor added in a later
    version is a new action, so a match on it ends in a catch-all that denies.
*)
type action = Wire.action =
  | View  (** the page, the live state, the jobs and a job's detail *)
  | Cancel
  | Retry
  | Delete
  | Run_again  (** a copy of a job enqueued *)
  | Pause  (** a queue *)
  | Resume
  | Set_limits  (** a queue's *)
  | Run_schedule  (** now *)

val routes :
  ?at:Spindle.Path.path ->
  ?stream_for:Mtime.Span.t ->
  operator:'p Spindle.Access.principal ->
  may:('p -> action -> Spindle.Access.decision) ->
  pool:Spindle_postgres.Pool.t Spindle.Dep.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  unit ->
  Spindle.Route.t list
(** The page at [at] ([/spool]) and the routes under it, each asking [may] for
    its caller, by [operator], before it reads or does anything. [pool] is the
    application's database, where spool's tables are, as a resource it already
    holds. [mono_clock] times the live state's reads, once a second, by one
    fiber of the process while anyone watches.

    A live stream ends after [stream_for] (a minute), and the page opens the
    next at once, asking [may] again: a viewer whose access the application has
    taken away sees the queue no longer than that, since a stream is one request
    and is asked once.

    Under [at]: [GET /api/live], the live state as Server-Sent Events --
    [allowed], the actions [may] allows the viewer, then [counts], [queues],
    [runners], [schedules] and [chart], each sent first whole, then whenever it
    changes; [GET /api/jobs], a page of jobs, newest first, by [state], [queue]
    and [kind], the next page [before] the last one's id; [GET /api/jobs/{id}],
    one job with its attempts, its payload and its workflow;
    [POST /api/jobs/cancel], [/retry] and [/delete], each given [{"ids": [...]}]
    and answering which jobs it changed and which it left;
    [POST /api/jobs/{id}/again]; [POST /api/queues/{queue}/pause], [/resume],
    and [/limits], given [{"running", "rate", "per_partition"}] as
    {!Spool.Queue.set_limits} takes them; and
    [POST /api/schedules/{schedule}/run]. *)
