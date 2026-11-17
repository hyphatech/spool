(* See cron.mli. *)

let ( let* ) = Result.bind

type t = {
  expression : string;
  zone_name : string;
  zone : Timedesc.Time_zone.t;
  minutes : bool array;
  hours : bool array;
  days : bool array;  (** 1 to 31, at their own index *)
  months : bool array;  (** 1 to 12, at their own index *)
  weekdays : bool array;  (** 0 Sunday to 6 *)
  any_day : bool;  (** the day of the month field began with [*] *)
  any_weekday : bool;
}

let expression t = t.expression
let zone t = t.zone_name

let aliases =
  [
    ("@hourly", "0 * * * *");
    ("@daily", "0 0 * * *");
    ("@midnight", "0 0 * * *");
    ("@weekly", "0 0 * * 0");
    ("@monthly", "0 0 1 * *");
    ("@yearly", "0 0 1 1 *");
    ("@annually", "0 0 1 1 *");
  ]

(* One field, its values marked in an array as long as its largest. *)
let field ~what ~lo ~hi text =
  let set = Array.make (hi + 1) false in
  let number s =
    match int_of_string_opt s with
    | Some n when n >= lo && n <= hi -> Ok n
    | Some _ | None ->
        Error (Printf.sprintf "%s: %S is not %d to %d" what s lo hi)
  in
  let item s =
    let range, step =
      match String.index_opt s '/' with
      | None -> (s, None)
      | Some i ->
          ( String.sub s 0 i,
            Some (String.sub s (i + 1) (String.length s - i - 1)) )
    in
    let* step =
      match step with
      | None -> Ok 1
      | Some n -> (
          match int_of_string_opt n with
          | Some n when n >= 1 -> Ok n
          | Some _ | None ->
              Error
                (Printf.sprintf "%s: the step %S is not a whole number above 0"
                   what n))
    in
    let* first, last =
      if String.equal range "*" then Ok (lo, hi)
      else
        match String.index_opt range '-' with
        | None ->
            let* n = number range in
            (* A value with a step runs from it to the field's end. *)
            Ok (n, if step > 1 then hi else n)
        | Some i ->
            let* a = number (String.sub range 0 i) in
            let* b =
              number (String.sub range (i + 1) (String.length range - i - 1))
            in
            if a > b then
              Error
                (Printf.sprintf "%s: the range %S runs backwards" what range)
            else Ok (a, b)
    in
    let rec mark n =
      if n <= last then (
        set.(n) <- true;
        mark (n + step))
    in
    mark first;
    Ok ()
  in
  let rec items = function
    | [] -> Ok set
    | s :: rest ->
        let* () = item s in
        items rest
  in
  if String.length text = 0 then Error (what ^ " is empty")
  else items (String.split_on_char ',' text)

let parse text ~zone:zone_name =
  let text = String.trim text in
  let text = Option.value (List.assoc_opt text aliases) ~default:text in
  match Timedesc.Time_zone.make zone_name with
  | None ->
      Error (Printf.sprintf "%S is no time zone of the tz database" zone_name)
  | Some zone -> (
      match
        List.filter
          (fun s -> String.length s > 0)
          (String.split_on_char ' ' text)
      with
      | [ mi; h; d; mo; w ] ->
          let* minutes = field ~what:"the minute" ~lo:0 ~hi:59 mi in
          let* hours = field ~what:"the hour" ~lo:0 ~hi:23 h in
          let* days = field ~what:"the day of the month" ~lo:1 ~hi:31 d in
          let* months = field ~what:"the month" ~lo:1 ~hi:12 mo in
          let* week = field ~what:"the day of the week" ~lo:0 ~hi:7 w in
          let weekdays =
            Array.init 7 (fun i -> week.(i) || (i = 0 && week.(7)))
          in
          let starred s = String.length s > 0 && Char.equal s.[0] '*' in
          Ok
            {
              expression = text;
              zone_name;
              zone;
              minutes;
              hours;
              days;
              months;
              weekdays;
              any_day = starred d;
              any_weekday = starred w;
            }
      | _ ->
          Error
            (Printf.sprintf
               "%S is not five fields: minute, hour, day, month, day of the \
                week"
               text))

let weekday_index : Timedesc.weekday -> int = function
  | `Sun -> 0
  | `Mon -> 1
  | `Tue -> 2
  | `Wed -> 3
  | `Thu -> 4
  | `Fri -> 5
  | `Sat -> 6

(* Cron's rule: where both days are restricted, either matches. *)
let day_matches t ~day ~weekday =
  match (t.any_day, t.any_weekday) with
  | true, true -> true
  | true, false -> t.weekdays.(weekday)
  | false, true -> t.days.(day)
  | false, false -> t.days.(day) || t.weekdays.(weekday)

(* The instant a local time names in the zone: the first of two where the
   clock repeats it, and where it skips it, the first local time after it
   that exists, which is the instant the clock changed. *)
let instant t ~year ~month ~day ~hour ~minute =
  let at hour minute =
    match
      Timedesc.make ~tz:t.zone ~year ~month ~day ~hour ~minute ~second:0 ()
    with
    | Ok d ->
        Timedesc.Utils.ptime_of_timestamp
          (Timedesc.min_of_local_date_time_result (Timedesc.to_timestamp d))
    | Error _ -> None
  in
  (* A gap is at most a few hours, and never crosses midnight in a zone
     the tz database knows, so the minutes left in the day bound the walk. *)
  let rec first_existing m =
    if m >= 24 * 60 then None
    else
      match at (m / 60) (m mod 60) with
      | Some p -> Some p
      | None -> first_existing (m + 1)
  in
  first_existing ((hour * 60) + minute)

(* Nine years: past a leap day's longest wait, eight years across a century
   that skips one. *)
let horizon_days = 9 * 366

let next t ~after =
  match
    Timedesc.of_timestamp ~tz_of_date_time:t.zone
      (Timedesc.Utils.timestamp_of_ptime after)
  with
  | None -> None
  | Some local ->
      let start = Timedesc.date local in
      let start_ptime =
        Ptime.of_date
          ( Timedesc.Date.year start,
            Timedesc.Date.month start,
            Timedesc.Date.day start )
      in
      let rec day k =
        if k > horizon_days then None
        else
          match
            Option.bind start_ptime (fun p ->
                Ptime.add_span p (Ptime.Span.of_int_s (k * 86_400)))
          with
          | None -> None
          | Some p -> (
              let year, month, d = Ptime.to_date p in
              let weekday = weekday_index (Ptime.weekday p) in
              if not (t.months.(month) && day_matches t ~day:d ~weekday) then
                day (k + 1)
              else
                let rec minute_of_day m =
                  if m >= 24 * 60 then None
                  else
                    let hour = m / 60 and minute = m mod 60 in
                    if not (t.hours.(hour) && t.minutes.(minute)) then
                      minute_of_day (m + 1)
                    else
                      match instant t ~year ~month ~day:d ~hour ~minute with
                      | Some at when Ptime.is_later at ~than:after -> Some at
                      | Some _ | None -> minute_of_day (m + 1)
                in
                match minute_of_day 0 with
                | Some at -> Some at
                | None -> day (k + 1))
      in
      day 0
