let () =
  Eio_main.run @@ fun env ->
  let routes =
    Spool_dashboard.routes ~at:Spindle.Path.root
      ~operator:
        (Spindle.Access.principal ~id:(fun () -> "") (Spindle.Dep.return ()))
      ~may:(fun () _ -> Spindle.Access.Allow)
      ~pool:(Spindle.Dep.of_resource "database")
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ()
  in
  match Spindle.App.make routes with
  | Error e ->
      prerr_endline e;
      exit 1
  | Ok app -> (
      match
        Spindle.Melange.client
          ~header:
            "Written by dashboard/web/printer/client.exe from the dashboard's \
             routes, as the build runs; never edited."
          app
      with
      | Ok client -> print_string client
      | Error problems ->
          List.iter prerr_endline problems;
          exit 1)
