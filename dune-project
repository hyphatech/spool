(lang dune 3.18)
(name spool)

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
 (synopsis "A durable job queue in your own Postgres, for OCaml 5 and Eio")
 (description
  "A job is a row written in the transaction that made it owed, claimed by a runner under a lease, run outside any transaction, retried with backoff and finished once, however often it was attempted.")
 (depends
  (ocaml (>= 5.5))
  (rowtype (and (>= 0.8.0) (< 0.9.0)))
  (rowtype-postgres (and (>= 0.8.0) (< 0.9.0)))
  (ptime (>= 1.2.0))
  (wiretype (and (>= 0.5.0) (< 0.6.0)))
  (eio (>= 1.5))
  (logs (>= 0.10.0))
  (mtime (>= 2.1.0))
  (eio_main (and :with-test (>= 1.5)))
  (alcotest (and :with-test (>= 1.9.1)))
  (merlin (and :with-dev-setup (>= 5.6-504)))
  (ocaml-lsp-server (and :with-dev-setup (>= 1.24.0)))
  (ocamlformat (and :with-dev-setup (= 0.29.0)))
  (odoc (and :with-dev-setup (>= 3.2.1)))))
