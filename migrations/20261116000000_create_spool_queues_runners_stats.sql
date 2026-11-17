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
