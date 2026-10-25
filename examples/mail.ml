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
