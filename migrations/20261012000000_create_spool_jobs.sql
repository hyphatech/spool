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
