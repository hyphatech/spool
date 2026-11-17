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
