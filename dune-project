(lang dune 3.18)
(name spool)

(using melange 0.1)

; The dashboard's front end is OCaml with JSX, read by mlx.

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (merlin_reader mlx)
  (format
   (run ocamlformat-mlx --impl %{input-file}))
  (preprocess
   (run mlx-pp %{input-file}))))

(implicit_transitive_deps false)

(generate_opam_files true)

(maintainers "Hypha Technologies Ltd <dev@hyphatech.io>")

(authors "Hypha Technologies Ltd")

(license MIT)

(maintenance_intent "(latest)")

(source
 (github hyphatech/spool))

(package
 (name spool)
 (synopsis "Durable jobs for modern OCaml, backed by Postgres")
 (description
  "A job is a row written in the transaction that made it owed, claimed by a runner under a lease, run outside any transaction, retried with backoff and finished once, however often it was attempted.")
 (depends
  (ocaml (>= 5.5))
  (rowtype (and (>= 0.10.0) (< 0.11.0)))
  (rowtype-postgres (and (>= 0.10.0) (< 0.11.0)))
  (ptime (>= 1.2.0))
  (wiretype (and (>= 0.7.0) (< 0.8.0)))
  (eio (>= 1.5))
  (logs (>= 0.10.0))
  (mtime (>= 2.1.0))
  (timedesc (>= 3.1.2))
  (eio_main (and :with-test (>= 1.5)))
  (alcotest (and :with-test (>= 1.9.1)))
  (hypha-litany (and :with-dev-setup (>= 1.2.2) (< 2.0.0)))
  (merlin (and :with-dev-setup (>= 5.6-504)))
  (ocaml-lsp-server (and :with-dev-setup (>= 1.25.0)))
  (ocamlformat (and :with-dev-setup (= 0.29.0)))
  (odoc (and :with-dev-setup (>= 3.2.1)))))

(package
 (name spool-dashboard)
 (synopsis "A live dashboard for spool, as routes of a Spindle application")
 (description
  "Watch and steer spool's queue from the application that runs it: counts by state and queue, the runners, the queues and their limits, schedules, workflows and a chart of attempts, live, with cancel, retry and delete for a job or a selection. Routes added to a Spindle server behind its own guard; the page is built in and served from memory.")
 (depends
  (ocaml (>= 5.5))
  (spool (= :version))
  (spindle (and (>= 0.15.0) (< 0.16.0)))
  (spindle-postgres (and (>= 0.15.0) (< 0.16.0)))
  (rowtype (and (>= 0.10.0) (< 0.11.0)))
  (rowtype-postgres (and (>= 0.10.0) (< 0.11.0)))
  (wiretype (and (>= 0.7.0) (< 0.8.0)))
  (ppx_wiretype (and (>= 0.7.0) (< 0.8.0)))
  (ptime (>= 1.2.0))
  (mtime (>= 2.1.0))
  (eio (>= 1.6))
  (logs (>= 0.10.0))
  ; The page's committed bundle, made a module as the package builds.
  (crunch (and :build (>= 4.1.0)))
  (spindle-http (and :with-test (>= 0.15.0) (< 0.16.0)))
  (eio_main (and :with-test (>= 1.6)))
  (alcotest (and :with-test (>= 1.9.1)))
  ; The front end the bundle is built from, compiled by Melange with the
  ; tests; nothing of it is installed, since the bundle is.
  (melange (and :with-test (>= 7.0.1-55)))
  (mlx (and :with-test (>= 0.11)))
  (ppx_solidtype (and :with-test (>= 0.11.0) (< 0.12.0)))
  (solidtype (and :with-test (>= 0.11.0) (< 0.12.0)))
  (solidtype-heroui (and :with-test (>= 0.11.0) (< 0.12.0)))
  (solidtype-rhp (and :with-test (>= 0.11.0) (< 0.12.0)))
  (solidtype-gravity-icons (and :with-test (>= 0.11.0) (< 0.12.0)))
  (ocamlformat-mlx (and :with-dev-setup (= 0.29.0.1)))))
