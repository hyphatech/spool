(** A five-field cron expression -- minute, hour, day of the month, month, day
    of the week -- read in a time zone, and the instants it names. *)

type t

val parse : string -> zone:string -> (t, string) result
(** [parse "0 8 * * 1-5" ~zone:"Europe/London"]. A field is [*], a value, a
    range [a-b], a step [*/n] or [a-b/n], or a list of them; a day of the week
    is 0 to 7, Sunday both 0 and 7. [@hourly], [@daily], [@midnight], [@weekly],
    [@monthly], [@yearly] and [@annually] name their usual expressions. Where
    both days are restricted, a day either names is matched, as cron does.
    [zone] is a name of the tz database; [UTC] is one. *)

val next : t -> after:Ptime.t -> Ptime.t option
(** The first instant it names after [after], within about nine years; [None]
    where there is none, as for the thirtieth of February. A local time the
    zone's clock skips names the first instant after the change; one it repeats
    names its first instance only, so a clock change runs a tick once. *)

val expression : t -> string
val zone : t -> string
