# The table

spool keeps its jobs in one table, `spool_jobs` (`Spool.table`), and what
its runners share beside them in more, all made by its own
migrations. They are plain SQL, installed with the package in
`share/spool/migrations`, and applied beside your own as a history of their
own, before your application starts:

```sh
rowtype-migrate up --source spool    # spool's migrations, then yours
```

`--source` needs rowtype 0.5.0 or later; [rowtype's
migrations](https://hyphatech.github.io/rowtype/) say the rest of the
command. An upgrade of spool that changes the table ships a new migration,
and the same command applies it. With another migration tool, copy the
files from `$(opam var spool:share)/migrations` into its folder: they are
plain Postgres.

## Checked before a runner starts

A runner checks the table before it starts, and refuses a database where it
is missing or behind, naming the command to run: `Runner.create` answers
`Unmigrated`, with each problem it found.

`Spool.statements` is every statement the package runs, for
`Rowtype_postgres.verify` beside your own. A test that runs it finds a
migration that broke one before a job does:

```ocaml title="verify.ml"
(* A test that every statement the application runs is what its database
   says, spool's among them, so a migration that renamed a column fails a
   test and not a job.

     dune exec examples/verify.exe *)

module Pg = Rowtype_postgres

let database = "postgres://postgres:postgres@localhost:5432/postgres"

let orders =
  Rowtype.list ~params:Rowtype.unit
    ~row:Rowtype.(t2 int text)
    "select id, email from orders order by id"

let check conn =
  match Pg.verify conn (Spool.statements @ [ Rowtype.Any orders ]) with
  | Ok () -> print_endline "Every statement agrees with the database."
  | Error (`Disagreements problems) -> List.iter prerr_endline problems
  | Error (#Rowtype.error as e) -> prerr_endline (Rowtype.error_to_string e)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Pg.Conninfo.of_string database with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      match
        Pg.connect ~sw ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          conninfo
      with
      | Error e -> prerr_endline (Rowtype.error_to_string e)
      | Ok conn ->
          check conn;
          Pg.close conn)
```

## States

Six states, and the rest derived: *scheduled* is `available` with a later
`scheduled_at`, *retrying* is `available` with an attempt made.

| State | What it means |
|---|---|
| `available` | waiting, or scheduled, or to be retried |
| `blocked` | waiting for jobs it was enqueued after |
| `running` | claimed by a runner, under its lease |
| `completed` | its handler answered `Ok` |
| `discarded` | failed on its last attempt, expired, or given up |
| `cancelled` | cancelled by an operator |

## Columns

| Column | What it holds |
|---|---|
| `queue` | The queue a runner claims it from, with that queue's concurrency. |
| `kind` | What runs it: a kind's name, its identity, so a changed payload shape is a new kind. |
| `payload` | What the job is given: an object, as its kind's description wrote it. |
| `priority` | 0 to 9, 0 first: before the instant and the order of enqueueing. |
| `state` | One of the six above. |
| `attempt` | Attempts begun: raised by the claim, so a job that kills its process uses one. |
| `max_attempts` | Its kind's attempts, when it was written. |
| `scheduled_at` | When it may run next. |
| `expires_at` | After when it is not worth running, and is discarded unrun. |
| `partition_key` | The partition its kind gave it, which a queue limited per partition counts by. |
| `unique_key` | Repeated asks of one kind with one key, folded into the job waiting. |
| `sensitive` | Whether its kind keeps its payload from every answer of spool's. |
| `unique_until` | Until when its key answers every enqueue with this job, whatever its state; its row is kept until then. |
| `runner` | The runner holding its lease, while it runs. |
| `lease_ends_at` | Until when its runner holds it, renewed while it runs; a lapsed one is rescued. |
| `inserted_at`, `attempted_at`, `finished_at` | When it was written, last claimed, and finished. |
| `errors` | Each failed attempt's attempt, instant and reason, oldest first. |

Every instant in it is the `now` a caller gave: no statement reads the
database's clock.

The migration that makes it

```sql title="migrations/20261012000000_create_spool_jobs.sql"
-- create_spool_jobs: the table of jobs, spool's own, made by its first migration.

create table spool_jobs (
  id            bigint generated always as identity primary key,
  queue         text not null,
  kind          text not null,
  payload       jsonb not null,
  priority      smallint not null,
  state         text not null,
  attempt       integer not null,
  max_attempts  integer not null,
  scheduled_at  timestamptz not null,
  expires_at    timestamptz,
  unique_key    text,
  runner        text,
  lease_ends_at   timestamptz,
  inserted_at   timestamptz not null,
  attempted_at  timestamptz,
  finished_at   timestamptz,
  errors        jsonb not null,
  constraint spool_jobs_state check (state in
    ('available', 'running', 'completed', 'discarded', 'cancelled')),
  constraint spool_jobs_priority check (priority between 0 and 9),
  constraint spool_jobs_attempts check (max_attempts >= 1 and attempt >= 0),
  constraint spool_jobs_running_leased check
    ((state = 'running') = (runner is not null and lease_ends_at is not null)),
  constraint spool_jobs_finished check
    ((state in ('completed', 'discarded', 'cancelled')) = (finished_at is not null))
);

create index spool_jobs_due on spool_jobs (queue, priority, scheduled_at, id)
  where state = 'available';
create index spool_jobs_leased on spool_jobs (lease_ends_at) where state = 'running';
create unique index spool_jobs_waiting_key on spool_jobs (kind, unique_key)
  where state = 'available' and unique_key is not null;
create index spool_jobs_finished_at on spool_jobs (finished_at)
  where state in ('completed', 'discarded', 'cancelled');

comment on table spool_jobs is 'Jobs: work owed, written in the transaction that made it owed, claimed by a runner under a lease, and finished once.';
comment on column spool_jobs.queue is 'The queue a runner claims it from, with that queue''s concurrency.';
comment on column spool_jobs.kind is 'What runs it: a kind''s name, its identity, so a changed payload shape is a new kind.';
comment on column spool_jobs.payload is 'What the job is given: an object, as its kind''s description wrote it.';
comment on column spool_jobs.priority is '0 to 9, 0 first: before the instant and the order of enqueueing.';
comment on column spool_jobs.state is 'available, running, completed, discarded or cancelled; scheduled and retrying are available with a later instant or an attempt made.';
comment on column spool_jobs.attempt is 'Attempts begun: raised by the claim, so a job that kills its process uses one.';
comment on column spool_jobs.scheduled_at is 'When it may run next.';
comment on column spool_jobs.expires_at is 'After when it is not worth running, and is discarded unrun.';
comment on column spool_jobs.unique_key is 'Repeated asks of one kind with one key, folded into the job waiting.';
comment on column spool_jobs.runner is 'The runner holding its lease, while it runs.';
comment on column spool_jobs.lease_ends_at is 'Until when its runner holds it, renewed while it runs; a lapsed one is rescued.';
comment on column spool_jobs.errors is 'Each failed attempt''s attempt, instant and reason, oldest first.';
```

## Beside the jobs

| Table | What it holds |
|---|---|
| `spool_queues` | A row a queue: whether it is paused, and its limits across every runner. Made when a runner first names the queue, or an operator pauses or limits it. |
| `spool_runners` | A row a runner running: its host, process, queues and last heartbeat. |
| `spool_stats` | A row a second, queue, kind and outcome: how many attempts finished, and how long they ran and waited. |
| `spool_starts` | The attempts begun in a queue with a rate, kept as long as its period. |
| `spool_partitions` | When each partition of a partitioned queue was last served. |
| `spool_schedules` | A row a schedule: its expression, zone, job, and next and last tick. |
| `spool_dependencies` | A row a job waiting for another: the waiting job, and the one it waits for. |

The migration that makes them

```sql title="migrations/20261116000000_create_spool_queues_runners_stats.sql"
-- create_spool_queues_runners_stats: what every runner shares beside the jobs -- each queue's
-- pause, the runners running, and what each second's attempts came to.

create table spool_queues (
  name        text primary key,
  paused      boolean not null,
  updated_at  timestamptz not null
);

create table spool_runners (
  id          text primary key,
  host        text not null,
  pid         integer not null,
  queues      jsonb not null,
  started_at  timestamptz not null,
  seen_at     timestamptz not null
);

create table spool_stats (
  second   timestamptz not null,
  queue    text not null,
  kind     text not null,
  outcome  text not null,
  count    integer not null,
  run_us   bigint not null,
  wait_us  bigint not null,
  primary key (second, queue, kind, outcome),
  constraint spool_stats_outcome check (outcome in ('completed', 'retried', 'discarded'))
);

comment on table spool_queues is 'A queue''s settings every runner obeys: a row a queue, made when a runner first names it.';
comment on column spool_queues.paused is 'Whether runners claim from it: a pause outlives every runner, until resumed.';
comment on table spool_runners is 'The runners running: each upserts its row at its heartbeat, deletes it as it stops, and one a lease late is deleted by any other.';
comment on column spool_runners.queues is 'The queues it runs and how many jobs of each it runs at once: [{"queue": ..., "slots": ...}].';
comment on table spool_stats is 'What attempts came to, a row a second, queue, kind and outcome, added to as each finishes: what a dashboard charts.';
comment on column spool_stats.run_us is 'The microseconds the second''s attempts ran, summed.';
comment on column spool_stats.wait_us is 'The microseconds they waited past their scheduled instant before a runner claimed them, summed.';
```

```sql title="migrations/20261116000001_limit_spool_queues.sql"
-- limit_spool_queues: a queue's limits across every runner -- how many of its jobs
-- run at once, how many attempts begin in a period, and whether both apply to
-- each partition of it -- the attempts begun that a rate counts, and when
-- each partition was last served.

alter table spool_queues
  add column running_limit integer,
  add column rate_attempts integer,
  add column rate_per_us bigint,
  add column per_partition boolean not null default false,
  add constraint spool_queues_running_limit check (running_limit >= 1),
  add constraint spool_queues_rate check
    ((rate_attempts is null) = (rate_per_us is null)
     and rate_attempts >= 1 and rate_per_us >= 1);

alter table spool_jobs add column partition_key text;

create table spool_starts (
  queue          text not null,
  partition_key  text not null,
  at             timestamptz not null
);

create table spool_partitions (
  queue          text not null,
  partition_key  text not null,
  claimed_at     timestamptz not null,
  primary key (queue, partition_key)
);

create index spool_starts_window on spool_starts (queue, partition_key, at);
create index spool_jobs_running_queue on spool_jobs (queue, partition_key)
  where state = 'running';

comment on column spool_queues.running_limit is 'How many of its jobs run at once across every runner, or of each partition''s; none, no limit.';
comment on column spool_queues.rate_attempts is 'How many attempts begin within rate_per_us, across every runner, or of each partition''s; none, no rate.';
comment on column spool_queues.per_partition is 'Whether its limit and rate hold for each partition of it, its partitions taken in turns.';
comment on column spool_jobs.partition_key is 'The partition its kind gave it, written at enqueue, so a claim reads a column and never a payload.';
comment on table spool_partitions is 'When each partition of a queue that has them was last claimed from: the one served longest ago is served next.';
comment on table spool_starts is 'Attempts begun in a queue with a rate, kept as long as its period: what the rate counts.';
```

```sql title="migrations/20261116000002_create_spool_schedules.sql"
-- create_spool_schedules: recurring jobs, a row a schedule, each advanced past
-- its tick by the transaction that enqueues the tick's job, so a tick is one
-- job however many runners hold the schedule.

create table spool_schedules (
  name           text primary key,
  expression     text not null,
  zone           text not null,
  kind           text not null,
  queue          text not null,
  payload        jsonb not null,
  priority       smallint not null,
  max_attempts   integer not null,
  partition_key  text,
  next_at        timestamptz not null,
  last_at        timestamptz,
  constraint spool_schedules_priority check (priority between 0 and 9),
  constraint spool_schedules_attempts check (max_attempts >= 1)
);

comment on table spool_schedules is 'Recurring jobs: written by every runner that holds the schedule, and advanced once per tick.';
comment on column spool_schedules.expression is 'The cron expression, five fields, read in zone.';
comment on column spool_schedules.zone is 'The tz database''s name of the zone the expression is read in.';
comment on column spool_schedules.next_at is 'The next tick: a runner past it enqueues the latest tick due and moves this past now, in one transaction guarded by its old value.';
comment on column spool_schedules.last_at is 'The tick last enqueued.';
```

```sql title="migrations/20261116000003_hold_spool_keys.sql"
-- hold_spool_keys: a unique key held for a period from enqueueing, whatever
-- its job's state, and the row kept until the period ends.

alter table spool_jobs add column unique_until timestamptz;

create index spool_jobs_held_key on spool_jobs (kind, unique_key, unique_until)
  where unique_until is not null;

comment on column spool_jobs.unique_until is 'Until when its key answers every enqueue of its kind with this job, in any state; its row is kept until then.';
```

```sql title="migrations/20261116000004_create_spool_dependencies.sql"
-- create_spool_dependencies: a job may wait for others, blocked until every one
-- of them completed, and cancelled once one of them cannot.

alter table spool_jobs drop constraint spool_jobs_state;
alter table spool_jobs add constraint spool_jobs_state check (state in
  ('available', 'blocked', 'running', 'completed', 'discarded', 'cancelled'));

create table spool_dependencies (
  job     bigint not null references spool_jobs (id) on delete cascade,
  on_job  bigint not null,
  primary key (job, on_job)
);

create index spool_dependencies_on on spool_dependencies (on_job);

comment on table spool_dependencies is 'A job waiting for another: its job blocked until every on_job completed, or is gone, which a completed job of a kind that keeps none is.';
comment on column spool_dependencies.on_job is 'The job waited for, with no reference, since a completed one may be pruned or deleted before its dependents run.';
```

```sql title="migrations/20261116000005_mark_sensitive_jobs.sql"
-- mark_sensitive_jobs: a job whose kind says its payload is sensitive, which no
-- read of spool's answers, and the indexes an operator's listing reads.

alter table spool_jobs add column sensitive boolean not null default false;
alter table spool_schedules add column sensitive boolean not null default false;

create index spool_jobs_listed on spool_jobs (state, id);
create index spool_jobs_blocked on spool_jobs (queue) where state = 'blocked';

comment on column spool_jobs.sensitive is 'Whether its kind keeps its payload from every answer of spool''s, as from every log line.';
```

```sql title="migrations/20261116000006_index_spool_finishes.sql"
-- index_spool_finishes: what finding the jobs whose attempts finished in a span
-- reads, a failure's job being scheduled or finished at or after it.

create index spool_jobs_scheduled on spool_jobs (scheduled_at);
```
