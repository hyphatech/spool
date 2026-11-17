(** The page's files, as Vite built them into [dashboard/assets/]: written by
    [ocaml-crunch] as the package builds, by their path below that directory --
    ["index.html"], ["assets/index-<hash>.js"]. *)

val file_list : string list
val read : string -> string option

val hash : string -> string option
(** Its bytes' MD5, in hexadecimal. *)

val size : string -> int option
