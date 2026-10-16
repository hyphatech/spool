# Changes

## 0.3.1 (2026-10-16)

- Installs from Hypha's opam repository:
  `opam repo add hypha https://github.com/hyphatech/opam-repository.git`,
  then `opam install spool`. The `pin-depends` are gone: spool takes
  wiretype 0.5 and rowtype 0.8, each up to its next breaking release.

## 0.3.0 (2026-10-14)

- Breaking: spool builds on rowtype 0.8.0, postgres-eio 0.5.0 and
  wiretype 0.5.0. A runner's failures are told by
  `Rowtype_postgres.error_to_string`, as every failure the backend
  answers is, so a connection that could not be made reads as rowtype
  tells it.

## 0.2.0 (2026-10-13)

- Breaking: spool builds on rowtype 0.6.0, postgres-eio 0.4.0 and
  wiretype 0.4.0. The `Rowtype_postgres.Conninfo.t` a runner is given is
  a private record there: one is made by `Conninfo.of_string`, and
  `{ c with database = name }` is `Conninfo.with_database c name`.

## 0.1.0 (2026-10-12)

- The queue, out of the application it was written in: a job is a row
  written in the transaction that made it owed, claimed by a runner under
  a lease, run outside every transaction, retried with backoff and
  finished once, however often it was attempted.
- Its table, `spool_jobs`, is made by spool's own migrations, installed
  with the package and applied with `rowtype-migrate up --source spool`;
  a runner refuses to start on a database where it is missing or behind.
