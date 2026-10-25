---
title: What it does not do yet
---

- **No periodic jobs.** A schedule that runs once across several processes
  needs a leader or a unique slot per instant; it is the first thing a
  second process asks for.
- **No limits across processes.** Concurrency is per runner: two runners of
  one queue run twice its concurrency, and there is no global rate.
- **No dependencies between jobs**, batches or workflows.
- **No pausing a queue**, and no fairness between keys: one key's many jobs
  run before another's few, in the order the claim reads.
- **A job's lines carry no request id or trace of the enqueuer's.** The
  runner's statements reach the application's observer, but nothing ties a
  job to the request that made it owed.
- **A queue's counts are exported nowhere.** `counts` answers them, and
  nothing turns them into metrics.
- **A handler that never yields cannot be stopped.** A timeout, a lost lease
  and stopping cancel a fiber at its next effect, so a handler busy on the
  CPU without one runs on until it ends.
- **Two clocks that disagree by more than a quarter of a lease** can run one
  job in two places: a lease is an instant from the claiming runner's
  `now`, compared against another's when it rescues.
