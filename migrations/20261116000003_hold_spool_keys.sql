-- hold_spool_keys: a unique key held for a period from enqueueing, whatever
-- its job's state, and the row kept until the period ends.

alter table spool_jobs add column unique_until timestamptz;

create index spool_jobs_held_key on spool_jobs (kind, unique_key, unique_until)
  where unique_until is not null;

comment on column spool_jobs.unique_until is 'Until when its key answers every enqueue of its kind with this job, in any state; its row is kept until then.';
