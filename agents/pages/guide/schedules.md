# Recurring jobs

A schedule enqueues a kind's job at each tick of a cron expression, read in
a time zone:

```ocaml
let nightly =
  Spool.Schedule.make ~name:"report.nightly" ~cron:"0 2 * * *"
    ~zone:"Europe/London" report { day = `Yesterday }

Spool.Runner.create ~schedules:[ nightly ] ...
```

Give the schedule to every runner, or to any of them: **a tick is one job
however many runners hold it.** Its row in `spool_schedules` keeps the next
tick, and the transaction that enqueues the tick's job moves it on, guarded
by the value it read, so of every runner that sees the tick due, one
enqueues it. No runner is elected, and none has to fail over.

## The expression

Five fields -- minute, hour, day of the month, month, day of the week --
each `*`, a value, a range `a-b`, a step `*/n` or `a-b/n`, or a list of
them; Sunday is both 0 and 7. `@hourly`, `@daily`, `@midnight`, `@weekly`,
`@monthly`, `@yearly` and `@annually` name their usual expressions. Where
both days are restricted, a day either names is a tick, as cron has it.

## The zone

`~zone` is required, a name of the tz database such as `Europe/London` or
`UTC`, because a business's 08:00 is local, and moves against UTC twice a
year. Where the clock goes forward and skips a tick's local time, the tick
is the instant the clock changes; where it goes back and repeats one, the
tick is its first instance alone.

## Missed ticks, and deploys

Ticks missed while no runner ran are enqueued once, the latest of them, so
an outage does not flood a queue. A schedule's next tick survives a deploy
while its expression and zone stay the same; change either and it starts
again from now.

A schedule that cannot run -- an expression that does not read or names no
instant, such as the thirtieth of February, a zone the tz database does not
have, a payload that cannot be written -- raises `Invalid_argument` where it
is made, as a kind does.

## By hand

`Spool.Schedule.list` answers every schedule a runner has held, with its
next and last tick. `Spool.Schedule.run_now conn ~now name` enqueues its job
now, beside its ticks, which it does not move.

In a test, `Runner.drain` enqueues every tick due at the clock's `now`
before it runs what is due.
