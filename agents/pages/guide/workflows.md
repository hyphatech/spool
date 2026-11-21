# Workflows

A job may wait for others. `Spool.enqueue_after` writes it `Blocked`, and it
runs, as any job does, once every job it waits for has completed:

```ocaml
let* rows = Spool.enqueue_many conn ~now import_row lines in
let* _ = Spool.enqueue_after conn ~now ~waits_for:rows summary file in
```

That is a batch with a summary, a workflow of one level; a job that waits
for the summary makes it two. There is nothing else to learn: a workflow is
its jobs and what each waits for.

## When one fails

A job that ends without completing -- discarded on its last attempt,
cancelled, expired, or deleted before it completed -- cancels every job
that waits on it, however far down, each with a reason naming the job that
ended and how. What waits on a job learns how it ended in the transaction
that records it, so no job is left blocked on one that has ended.

A job waited for that is gone counts as completed, since a completed job of
a kind that keeps none is deleted, and the rest are pruned after their
retention. One already discarded or cancelled when the job is enqueued
cancels it at once.

A retried job that waits for others waits again: retry what it waited for
first.

## No key

`enqueue_after` takes no unique key. A blocked job is outside the fold of
waiting jobs by key, and once released it would meet the job its key
already names.

## Looking at one

`Spool.workflow conn id` answers every job connected to one by waiting,
either way, with each one's `info`, and the edges between them as `(job,
waits_for)` pairs.
