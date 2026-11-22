# Operating a queue

`find`, `jobs`, `counts`, `cancel`, `retry`, `delete` and `run_again` are an
operator's hand, with a queue's pause and the list of runners. Each runs on
a connection of the caller's, as `enqueue` does, and takes a job by the
`Spool.Id.t` that `enqueue`, `retry` or `Runner.drain` answered. This
program enqueues a job, cancels it, retries it, finds it, and prints every
queue's counts:

```ocaml title="operating.ml"
(* An operator's hand: a job enqueued, found, cancelled and retried, and the
   queues' counts.

     dune exec examples/operating.exe *)

module Pg = Rowtype_postgres

let database = "postgres://postgres:postgres@localhost:5432/postgres"

let order =
  Wiretype.Object.map Fun.id
  |> Wiretype.Object.mem "order" Wiretype.string ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt = Spool.Kind.make ~queue:"mail" "receipt.send" order

let state_name : Spool.state -> string = function
  | Available -> "available"
  | Blocked -> "blocked"
  | Running -> "running"
  | Completed -> "completed"
  | Discarded -> "discarded"
  | Cancelled -> "cancelled"

let print_counts conn =
  match Spool.counts conn with
  | Error e -> prerr_endline (Rowtype.error_to_string e)
  | Ok counts ->
      List.iter
        (fun (queue, state, n) ->
          Printf.printf "%s %s %d\n" queue (state_name state) n)
        counts

let print_job conn id =
  match Spool.find conn id with
  | Error e -> prerr_endline (Rowtype.error_to_string e)
  | Ok None -> print_endline "no such job"
  | Ok (Some (job : Spool.info)) ->
      Printf.printf "%s in %s: %s, attempt %d of %d\n" job.kind job.queue
        (state_name job.state) job.attempt job.max_attempts;
      List.iter
        (fun (f : Spool.failed) ->
          Printf.printf "  attempt %d at %s: %s\n" f.attempt
            (Ptime.to_rfc3339 f.at) f.reason)
        job.errors

let cancel conn id =
  match Spool.cancel conn ~now:(Ptime_clock.now ()) id with
  | Ok true -> print_endline "cancelled"
  | Ok false -> print_endline "it had finished"
  | Error e -> prerr_endline (Rowtype.error_to_string e)

let retry conn id =
  match Spool.retry conn ~now:(Ptime_clock.now ()) id with
  | Ok (Some waiting) ->
      print_endline ("waiting as " ^ Spool.Id.to_string waiting)
  | Ok None -> print_endline "it was not discarded or cancelled"
  | Error e -> prerr_endline (Rowtype.error_to_string e)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match Pg.Conninfo.of_string database with
  | Error e -> prerr_endline e
  | Ok conninfo -> (
      match
        Pg.connect ~sw ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          conninfo
      with
      | Error e -> prerr_endline (Rowtype.error_to_string e)
      | Ok conn ->
          (match
             Spool.enqueue conn ~now:(Ptime_clock.now ()) receipt "A-1001"
           with
          | Ok id ->
              cancel conn id;
              retry conn id;
              print_job conn id;
              print_counts conn
          | Error (#Rowtype.error as e) ->
              prerr_endline (Rowtype.error_to_string e)
          | Error _ -> prerr_endline "the job could not be written");
          Pg.close conn)
```

## Counts

`Spool.counts` answers how many jobs each queue holds in each state.

A `Spool.state` is one of six: `Available` (waiting, or scheduled, or to
be retried), `Blocked` (waiting for jobs it was enqueued after), `Running`,
`Completed`, `Discarded` (failed on its last attempt, expired, or given up)
and `Cancelled`.

## Finding a job

`Spool.find` answers a job's `Spool.info`, or `None` where there is no such
row -- a job pruned, or one completed by a kind that keeps none; `print_job`
above reads one:

| Field | What it holds |
|---|---|
| `id`, `queue`, `kind` | The job, its queue and its kind's name |
| `state`, `priority` | Where it is, and its priority |
| `attempt`, `max_attempts` | Attempts begun, and how many it has |
| `scheduled_at` | When it may run next |
| `inserted_at`, `finished_at` | When it was written, and finished |
| `errors` | Each failed attempt: which, when, and why, in the handler's words, oldest first |
| `payload` | Its JSON, or `None` for a kind made `~sensitive` |

## Listing jobs

`Spool.jobs conn ~limit` answers jobs newest first, of a `~state`, a
`~queue` and a `~kind` where given; the next page is `~before` the last
one's id. `Spool.counts ~finished:false` counts only what waits, is blocked
and runs, from their indexes, without reading the finished rows retention
keeps: what a page that asks every second reads.

## Cancelling and retrying

A cancelled waiting job never runs and a cancelled running one is stopped
at its runner's next heartbeat; `cancel` answers `false` where it had
finished.

A retried job is available again from its first attempt with its reasons
kept, unless a job of its kind already waits under its key, which is then
the answer, and the retried row stays as it was, so one key never runs
twice. `retry` takes a discarded or cancelled job, and answers `None` for
any other, as `cancel` and `retry` above show.

## Deleting a job

`Spool.delete` removes a job's row, whatever its state but running, and
answers `false` for a running job or one there is not. A job deleted before
it completed cancels what waits on it, as a cancel does. Cancel a running job
first; once it has stopped, it can be deleted.

## Running a job again

`Spool.run_again conn ~now id` enqueues a new job, a copy of this one -- its
kind, queue, payload and settings -- from its first attempt, whatever this
one's state, and answers the copy's id. Its work is done again, as an
operator asks, so it has no unique key and waits for nothing. `retry` is for
a job that failed for good or was cancelled; `run_again` is for any, a
completed one among them.

## Pausing a queue

A queue's pause is kept in the table, not in any runner, so every runner
obeys it -- one started after it among them -- until it is resumed:

```ocaml
Spool.Queue.pause conn ~now "mail"     (* no runner claims from it *)
Spool.Queue.resume conn ~now "mail"    (* claimed from again, at once *)
```

What runs when a queue is paused runs to its end. `Spool.Queue.list` answers
every queue a runner has named, each with whether it is paused and its
limits ([Limiting a queue](limiting.md)).

## Runners

`Spool.Runner.list` answers the runners running: each one's host, process,
the queues it runs with how many jobs of each at once, when it started and
its last heartbeat. A runner writes its row at every heartbeat and deletes
it when it stops; one a lease late is deleted by another, so a runner killed
leaves the list within a lease.

## What attempts came to

`Spool.Stats.since conn instant` answers, a row a second, queue, kind and
outcome -- `Completed`, `Retried` or `Discarded` -- how many attempts
finished, how long they ran and how long they waited past their scheduled
instant, together. A runner counts each attempt in the transaction that
records it, and prunes the rows as it prunes completed jobs.
