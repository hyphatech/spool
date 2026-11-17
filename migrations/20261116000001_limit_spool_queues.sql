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
