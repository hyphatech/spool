# Kinds

A kind is a kind of job: its name, its payload's
[wiretype](https://hyphatech.github.io/wiretype/) description, and how it is
run. It is a constant, made once where the program's other constants are,
and shared by the code that enqueues and the runner that handles it:

```ocaml title="kinds.ml"
(* Kinds of job: a payload's description, and how each kind is run.

     dune exec examples/kinds.exe *)

(* {"order": "..."} *)
let order =
  Wiretype.Object.map (fun id -> id)
  |> Wiretype.Object.mem "order" Wiretype.string ~enc:Fun.id
  |> Wiretype.Object.finish

let receipt =
  Spool.Kind.make ~queue:"mail" ~timeout:Mtime.Span.min "receipt.send" order

(* A report is slow, rarely worth retrying, and holds what no row should keep
   once it is sent. *)
let report =
  Spool.Kind.make ~queue:"reports" ~priority:5 ~max_attempts:3
    ~timeout:Mtime.Span.(30 * min)
    ~backoff:(fun ~attempt ->
      let minutes = 10 * attempt in
      Mtime.Span.(minutes * min))
    ~keep:false "report.monthly" order

let () =
  List.iter print_endline
    [
      Spool.Kind.name receipt;
      Spool.Kind.name report;
      Spool.Kind.name Reminder.reminder;
    ]
```

## What a kind says

A kind is its name, its payload's `wiretype` description, its queue, its
priority (0 to 9, 0 first), its attempts (20), its timeout (five minutes),
its backoff and whether its rows are kept once completed. Each is an
argument of `Spool.Kind.make`:

| Argument | Unless given | What it is |
|---|---|---|
| `?queue` | `"default"` | The queue a runner claims it from |
| `?priority` | `0`, the first | 0 to 9: a job of a lower number runs before one due with it |
| `?max_attempts` | `20` | How many attempts it has before it is discarded |
| `?timeout` | five minutes | An attempt's bound: one past it is cancelled and is a failure |
| `?backoff` | 15 s doubled each attempt to at most six hours, spread by a tenth either way | How long the attempt after `attempt` waits: twenty attempts span about two and a half days |
| `?keep` | `true` | `false` deletes a job the moment it completes, so a payload that should not outlive its work does not |
| `?partition` | none | The partition a job is in, from its payload: what a queue limited per partition counts by ([Limiting a queue](limiting.md)) |
| `?sensitive` | `false` | Keeps its jobs' payloads from every answer of spool's -- `find`, `jobs`, the dashboard -- as every payload is kept from every log line |

`report` in `kinds.ml` above gives each of them.

Every instant the queue is given or answers is a `Ptime.t`, the caller's
`now`, and every duration an `Mtime.Span.t` named for what it bounds.

## Its name is its identity

A kind's name is its identity in the table: renaming one strands its
waiting jobs, so a changed payload shape is a new name. `Spool.Kind.name`
answers it.

## The payload is an object

The payload is an object, and `Kind.make` refuses a description of anything
else: each member is named for what it holds, so a row read in the table
says what each value is of -- a bare key names nothing -- and a kind gains
a member, with an `~absent`, without a new name:

```ocaml title="reminder.ml"
(* A kind whose payload gained a member, read with its default from a row
   written before it. kinds.ml names it. *)

type reminder = { invoice : string; channel : string }

(* {"invoice": "...", "channel": "email"}: "channel" was added later, and a
   row written before it reads as "email". *)
let reminder_payload =
  Wiretype.Object.map (fun invoice channel -> { invoice; channel })
  |> Wiretype.Object.mem "invoice" Wiretype.string ~enc:(fun r -> r.invoice)
  |> Wiretype.Object.mem "channel" Wiretype.string ~absent:"email"
       ~enc:(fun r -> r.channel)
  |> Wiretype.Object.finish

let reminder = Spool.Kind.make ~queue:"mail" "invoice.remind" reminder_payload
```

A row written before `channel` was added reads as `"email"`. A job whose
payload its kind's description no longer reads is discarded, its reason
saying so.

## What it refuses

An empty name or queue, a priority outside 0 to 9, attempts under one, a
timeout of zero, or a payload that is not an object raise
`Invalid_argument`: a kind is a constant written in source, so a program
that starts never meets one.
