-- mark_sensitive_jobs: a job whose kind says its payload is sensitive, which no
-- read of spool's answers, and the indexes an operator's listing reads.

alter table spool_jobs add column sensitive boolean not null default false;
alter table spool_schedules add column sensitive boolean not null default false;

create index spool_jobs_listed on spool_jobs (state, id);
create index spool_jobs_blocked on spool_jobs (queue) where state = 'blocked';

comment on column spool_jobs.sensitive is 'Whether its kind keeps its payload from every answer of spool''s, as from every log line.';
