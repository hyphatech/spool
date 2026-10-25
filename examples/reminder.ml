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
