# Changes

## 0.1.0 (2026-10-12)

- The queue, out of the application it was written in: a job is a row
  written in the transaction that made it owed, claimed by a runner under
  a lease, run outside every transaction, retried with backoff and
  finished once, however often it was attempted.
- Its table, `spool_jobs`, is made by spool's own migrations, installed
  with the package and applied with `rowtype-migrate up --source spool`;
  a runner refuses to start on a database where it is missing or behind.
