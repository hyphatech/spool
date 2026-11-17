---
title: Limiting a queue
---

A runner's slots bound what that runner runs. A queue's limits bound what
every runner of it runs together, and they live in the table, where every
runner reads them:

```ocaml
Spool.Queue.set_limits conn ~now "payments"
  ~running:(Some 5)
  ~rate:(Some { attempts = 60; per = Mtime.Span.min })
  ~per_partition:false
```

- **`running`**: how many of its jobs run at once, across every runner.
- **`rate`**: how many attempts begin in any period of `per`, across every
  runner: a partner's API that allows sixty calls a minute.
- Each call replaces all three; `None` is no limit.

A limit that could never let a job run -- no slot, no attempt, or a period
of nothing -- is refused as `` `Bad_limit ``, saying why.

## Partitions

A kind names the partition each of its jobs is in, from its payload:

```ocaml
let charge =
  Spool.Kind.make ~queue:"payments" ~partition:(fun c -> c.customer)
    "charge" charge_json
```

With `~per_partition:true`, `running` and `rate` hold for each partition:
`~running:(Some 1)` runs one customer's jobs one at a time, in order, while
other customers' run beside them. Partitions are taken in turns -- each
one's first job, then each one's second -- the one served longest ago
first, so a customer with one job waiting is not kept behind another's
hundred. Within a partition, jobs keep their order: priority, instant,
enqueueing.

## What it costs

A queue with neither limits nor partitions is claimed from as before. A
limited one is claimed from under a lock of its own, one runner at a time,
counting what runs and what began in the rate's period, so its claims cost
more: keep limits for the queues that need them.
