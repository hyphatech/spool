# Handlers

A handler is what one attempt at a job of a kind does. `Spool.handle` pairs
a kind with a function of the attempt and the payload, and the runner is
given the list:

```ocaml title="mail.ml"
(* A handler: what one attempt at a receipt does, and what its failure asks
   of the runner. runner.ml runs it. *)

let order =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem "order" Wiretype.string ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt = Spool.Kind.make ~queue:"mail" "receipt.send" order

(* Stands for a mail service's client; [key] makes a repeated send one. *)
let send ~key order :
    (unit, [ `Busy | `Slow_down of Mtime.Span.t | `No_such_address ]) result =
  Printf.printf "Receipt for order %s sent, keyed %s.\n%!" order key;
  Ok ()

let send_receipt (job : Spool.job) order =
  match send ~key:(Spool.Id.to_string job.id) order with
  | Ok () -> Ok ()
  | Error `Busy -> Error (Spool.Retry "the mail service is busy")
  | Error (`Slow_down wait) ->
      Error (Spool.Retry_in (wait, "the mail service said wait"))
  | Error `No_such_address -> Error (Spool.Discard "no such address")
```

## What it answers

A handler answers `Ok ()`, `Retry reason` (after the kind's backoff),
`Retry_in (span, reason)` (after what an upstream said) or `Discard reason`
(never again, and no attempt used: it cannot succeed however long it
waits). The reason is in words for an operator, kept with the attempt in
the job's `errors`.

A failed attempt that was the job's last discards it.

## A raise, and a timeout

A raise is a retry whose reason names the exception's constructor, never
its argument; the log line carries the rest. An attempt past its kind's
timeout is cancelled and is a failure.

A job's payload has no log level: no line the queue writes, at any level,
carries it.

## The attempt

`Spool.job` is the attempt a handler is running: its `id`, its `attempt`,
counting from one, its `max_attempts` and its `inserted_at`.

## At least once

What a job runs is at least once and finished once. A handler whose effect
must happen once is idempotent, or keyed by the job -- as the handler above
gives the mail service the job's id, so a receipt sent twice is one.
