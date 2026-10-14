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

; The Hypha libraries below are in no opam repository yet: dune takes each
; from its repository at the release's tag, and opam from the pin-depends
; of spool.opam.template, at the same tags.

(pin
 (url "git+https://github.com/hyphatech/wiretype.git#0.5.0")
 (package
  (name wiretype)
  (version 0.5.0)))

(pin
 (url "git+https://github.com/hyphatech/postgres-eio.git#0.5.0")
 (package
  (name postgres-eio)
  (version 0.5.0)))

(pin
 (url "git+https://github.com/hyphatech/rowtype.git#0.8.0")
 (package
  (name rowtype)
  (version 0.8.0))
 (package
  (name rowtype-postgres)
  (version 0.8.0)))

(package
 (name spool)
 (synopsis "A durable job queue in your own Postgres, for OCaml 5 and Eio")
 (description
  "A job is a row written in the transaction that made it owed, claimed by a runner under a lease, run outside any transaction, retried with backoff and finished once, however often it was attempted.")
 (depends
  (ocaml (>= 5.5))
  (rowtype (>= 0.7.0))
  (rowtype-postgres (>= 0.7.0))
  (ptime (>= 1.2.0))
  (wiretype (>= 0.5.0))
  (eio (>= 1.5))
  (logs (>= 0.10.0))
  (mtime (>= 2.1.0))
  (eio_main (and :with-test (>= 1.5)))
  (alcotest (and :with-test (>= 1.9.1)))))
