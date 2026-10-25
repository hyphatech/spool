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
