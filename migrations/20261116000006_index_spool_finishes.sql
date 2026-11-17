-- index_spool_finishes: what finding the jobs whose attempts finished in a span
-- reads, a failure's job being scheduled or finished at or after it.

create index spool_jobs_scheduled on spool_jobs (scheduled_at);
