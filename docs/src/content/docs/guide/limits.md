---
title: What it does not do yet
---

- **A job's lines carry no request id or trace of the enqueuer's.** The
  runner's statements reach the application's observer, but nothing ties a
  job to the request that made it owed.
- **A queue's counts are exported nowhere.** `counts` answers them, and
  nothing turns them into metrics.
- **The dashboard needs a Spindle server.** `spool-dashboard` is routes of
  one, and nothing serves it without.
- **A handler that never yields cannot be stopped.** A timeout, a lost lease
  and stopping cancel a fiber at its next effect, so a handler busy on the
  CPU without one runs on until it ends.
- **Two clocks that disagree by more than a quarter of a lease** can run one
  job in two places: a lease is an instant from the claiming runner's
  `now`, compared against another's when it rescues.
