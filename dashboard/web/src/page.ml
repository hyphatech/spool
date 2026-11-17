(* What every part of the page shares: where its routes are, and the words
   and colours it shows a state, a time and a failure in. *)

external pathname : string = "pathname" [@@mel.scope "window", "location"]

(* The routes are under the page's own path, wherever a proxy put it:
   [/admin/spool] calls [/admin/spool/api/...]. *)
let origin () =
  let path = pathname in
  if String.ends_with ~suffix:"/" path then
    String.sub path 0 (String.length path - 1)
  else path

type state = Api.job_state =
  | Available
  | Blocked
  | Running
  | Completed
  | Discarded
  | Cancelled

let states = [ Available; Blocked; Running; Completed; Discarded; Cancelled ]

let state_label = function
  | Available -> "Available"
  | Blocked -> "Blocked"
  | Running -> "Running"
  | Completed -> "Completed"
  | Discarded -> "Discarded"
  | Cancelled -> "Cancelled"

(* A state as a list's key. *)
let state_key s = String.lowercase_ascii (state_label s)

let state_of_key key =
  List.find_opt (fun s -> String.equal (state_key s) key) states

let state_equal a b =
  match (a, b) with
  | Available, Available
  | Blocked, Blocked
  | Running, Running
  | Completed, Completed
  | Discarded, Discarded
  | Cancelled, Cancelled ->
      true
  | (Available | Blocked | Running | Completed | Discarded | Cancelled), _ ->
      false

(* Running is the accent, what is done its tone -- tip, danger -- and what
   waits or was stopped neutral, so the eye goes to what moves and what
   failed; caution is the chart's, for what was retried. *)
let state_colour :
    state -> [ `accent | `danger | `default | `success | `warning ] = function
  | Available -> `default
  | Blocked -> `default
  | Running -> `accent
  | Completed -> `success
  | Discarded -> `danger
  | Cancelled -> `default

let to_query : state -> Api.get_api_jobs_state = function
  | Available -> Available
  | Blocked -> Blocked
  | Running -> Running
  | Completed -> Completed
  | Discarded -> Discarded
  | Cancelled -> Cancelled

type action = Api.get_api_live_allowed_data_item =
  | View
  | Cancel
  | Retry
  | Delete
  | Run_again
  | Pause
  | Resume
  | Set_limits
  | Run_schedule

let action_equal a b =
  match (a, b) with
  | View, View
  | Cancel, Cancel
  | Retry, Retry
  | Delete, Delete
  | Run_again, Run_again
  | Pause, Pause
  | Resume, Resume
  | Set_limits, Set_limits
  | Run_schedule, Run_schedule ->
      true
  | ( ( View | Cancel | Retry | Delete | Run_again | Pause | Resume | Set_limits
      | Run_schedule ),
      _ ) ->
      false

(* Whether the server said its viewer may: what it did not say is not shown,
   and refused if asked for anyway. *)
let may (allowed : action array) action =
  Array.exists (action_equal action) allowed

(* The page loaded again, the browser's own: what a page out of date with
   its server does. *)
external reload : unit -> unit = "reload" [@@mel.scope "window", "location"]

let ms (t : Api.Instant.t) = Js.Date.getTime (Api.Instant.to_date t)
let count n = string_of_int (int_of_float n)

(* A span of time as an operator reads it at a glance. *)
let span seconds =
  let s = int_of_float (Float.abs seconds) in
  if s < 60 then string_of_int s ^ "s"
  else if s < 3600 then string_of_int (s / 60) ^ "m"
  else if s < 86400 then string_of_int (s / 3600) ^ "h"
  else string_of_int (s / 86400) ^ "d"

(* How long before [now] [at] was, or how long after: [now] is the server's
   latest second, so a browser's clock that is off says nothing wrong. *)
let ago ~now at =
  let d = (now -. ms at) /. 1000. in
  if d < 1. then "now" else span d ^ " ago"

let until ~now at =
  let d = (ms at -. now) /. 1000. in
  if d < 1. then "due" else "in " ^ span d

let instant (t : Api.Instant.t) = Js.Date.toLocaleString (Api.Instant.to_date t)
let json (value : Js.Json.t) = Js.Json.stringifyWithSpace value 2

let said = function
  | `Refused (r : Api.refusal) -> r.message
  | `Invalid ((p : Api.Problem.t) :: _) -> p.message
  | `Invalid [] -> "That is not quite right."
  | `Lost _ -> "The server cannot be reached."
  | `Unexpected _ -> "Something went wrong at our end."

(* A call whose answer is [ok]'s to say, or a toast saying why it was not
   done: past the client, a promise never rejects. *)
let settle call ~ok =
  ignore
    (Js.Promise.then_
       (fun answered ->
         (match answered with
         | Ok v -> ok v
         | Error e ->
             ignore
               (Solidtype_heroui.Toast.danger ~description:(said e) "Not done"
                 : Solidtype_heroui.Toast.key));
         Js.Promise.resolve ())
       call
      : unit Js.Promise.t)
