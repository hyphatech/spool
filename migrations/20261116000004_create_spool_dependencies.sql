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
