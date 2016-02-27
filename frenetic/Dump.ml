open Core.Std

(*===========================================================================*)
(* UTILITY FUNCTIONS                                                         *)
(*===========================================================================*)

let with_file (file : string) ~(f:in_channel -> 'a) : 'a =
  match Sys.file_exists file with
  | `No -> failwith (sprintf "File \"%s\" expexted but not found." file)
  | `Unknown -> failwith (sprintf "No read permission for file \"%s\"." file)
  | `Yes -> In_channel.with_file ~f file

let parse_pol ?(json=false) file =
  with_file file ~f:(fun chan -> match json with
    | false ->
      In_channel.input_all chan
      |> Frenetic_NetKAT_Parser.policy_from_string
    | true ->
      Frenetic_NetKAT_Json.policy_from_json_channel chan)

let parse_pred file =
  with_file file ~f:(fun chan ->
    In_channel.input_all chan
    |> Frenetic_NetKAT_Parser.pred_from_string)

let fmt = Format.formatter_of_out_channel stdout
let _ = Format.pp_set_margin fmt 120

let print_fdd fdd =
  printf "%s\n" (Frenetic_NetKAT_Compiler.to_string fdd)

let dump_fdd fdd =
  printf "%s\n" (Frenetic_NetKAT_Compiler.to_string fdd)

let print_table fdd sw =
  Frenetic_NetKAT_Compiler.to_table sw fdd
  |> Frenetic_OpenFlow.string_of_flowTable ~label:(sprintf "Switch %Ld" sw)
  |> printf "%s\n"

let print_all_tables ?(no_tables=false) fdd switches =
  if not no_tables then List.iter switches ~f:(print_table fdd)

let time f =
  let t1 = Unix.gettimeofday () in
  let r = f () in
  let t2 = Unix.gettimeofday () in
  (t2 -. t1, r)

let print_time time =
  printf "Compilation time: %.4f\n" time


(*===========================================================================*)
(* FLAGS                                                                     *)
(*===========================================================================*)

module Flag = struct
  open Command.Spec

  let switches =
    flag "--switches" (optional int)
      ~doc:"n number of switches to dump flow tables for (assuming \
            switch-numbering 1,2,...,n)"

  let print_fdd =
    flag "--print-fdd" no_arg
      ~doc:" print an ASCI encoding of the intermediate representation (FDD) \
            generated by the local compiler"

  let dump_fdd =
    flag "--dump-fdd" no_arg
      ~doc:" dump a dot file encoding of the intermediate representation \
            (FDD) generated by the local compiler"

  let print_auto =
    flag "--print-auto" no_arg
      ~doc:" print an ASCI encoding of the intermediate representation \
            generated by the global compiler (symbolic NetKAT automaton)"

  let dump_auto =
    flag "--dump-auto" no_arg
      ~doc:" dump a dot file encoding of the intermediate representation \
            generated by the global compiler (symbolic NetKAT automaton)"

  let print_global_pol =
    flag "--print-global-pol" no_arg
      ~doc: " print global NetKAT policy generated by the virtual compiler"

  let no_tables =
    flag "--no-tables" no_arg
      ~doc: " Do not print tables."

  let json =
    flag "--json" no_arg
      ~doc: " Parse input file as JSON."

  let vpol =
    flag "--vpol" (optional_with_default "vpol.dot" file)
      ~doc: "file Virtual policy. Must not contain links. \
             If not specified, defaults to vpol.dot"

  let vrel =
    flag "--vrel" (optional_with_default "vrel.kat" file)
      ~doc: "file Virtual-physical relation. If not specified, defaults to vrel.kat"

  let vtopo =
    flag "--vtopo" (optional_with_default "vtopo.kat" file)
      ~doc: "file Virtual topology. If not specified, defaults to vtopo.kat"

  let ving_pol =
    flag "--ving-pol" (optional_with_default "ving_pol.kat" file)
      ~doc: "file Virtual ingress policy. If not specified, defaults to ving_pol.kat"

  let ving =
    flag "--ving" (optional_with_default "ving.kat" file)
      ~doc: "file Virtual ingress predicate. If not specified, defaults to ving.kat"

  let veg =
    flag "--veg" (optional_with_default "veg.kat" file)
      ~doc: "file Virtual egress predicate. If not specified, defaults to veg.kat"

  let ptopo =
    flag "--ptopo" (optional_with_default "ptopo.kat" file)
      ~doc: "file Physical topology. If not specified, defaults to ptopo.kat"

  let ping =
    flag "--ping" (optional_with_default "ping.kat" file)
      ~doc: "file Physical ingress predicate. If not specified, defaults to ping.kat"

  let peg =
    flag "--peg" (optional_with_default "peg.kat" file)
      ~doc: "file Physical egress predicate. If not specified, defaults to peg.kat"
end


(*===========================================================================*)
(* COMMANDS: Local, Global, Virtual                                          *)
(*===========================================================================*)

module Local = struct
  let spec = Command.Spec.(
    empty
    +> anon ("file" %: file)
    +> Flag.switches
    +> Flag.print_fdd
    +> Flag.dump_fdd
    +> Flag.no_tables
    +> Flag.json
  )

  let run file nr_switches printfdd dumpfdd no_tables json () =
    let pol = parse_pol ~json file in
    let (t, fdd) = time (fun () -> Frenetic_NetKAT_Compiler.compile_local pol) in
    let switches = match nr_switches with
      | None -> Frenetic_NetKAT_Semantics.switches_of_policy pol
      | Some n -> List.range 0 n |> List.map ~f:Int64.of_int
    in
    if Option.is_none nr_switches && List.is_empty switches then
      printf "Number of switches not automatically recognized!\n\
              Use the --switch flag to specify it manually.\n"
    else
      if printfdd then print_fdd fdd;
      if dumpfdd then dump_fdd fdd;
      print_all_tables ~no_tables fdd switches;
      print_time t;
end



module Global = struct
  let spec = Command.Spec.(
    empty
    +> anon ("file" %: file)
    +> Flag.print_fdd
    +> Flag.dump_fdd
    +> Flag.print_auto
    +> Flag.dump_auto
    +> Flag.no_tables
    +> Flag.json
  )

  let run file printfdd dumpfdd printauto dumpauto no_tables json () =
    let pol = parse_pol ~json file in
    let (t, fdd) = time (fun () -> Frenetic_NetKAT_Compiler.compile_global pol) in
    let switches = Frenetic_NetKAT_Semantics.switches_of_policy pol in
    if printfdd then print_fdd fdd;
    if dumpfdd then dump_fdd fdd;
    print_all_tables ~no_tables fdd switches;
    print_time t;

end



module Virtual = struct
  let spec = Command.Spec.(
    empty
    +> anon ("file" %: file)
    +> Flag.vrel
    +> Flag.vtopo
    +> Flag.ving_pol
    +> Flag.ving
    +> Flag.veg
    +> Flag.ptopo
    +> Flag.ping
    +> Flag.peg
    +> Flag.print_fdd
    +> Flag.dump_fdd
    +> Flag.print_global_pol
  )

  let run vpol vrel vtopo ving_pol ving veg ptopo ping peg printfdd dumpfdd printglobal () =
    (* parse files *)
    let vpol = parse_pol vpol in
    let vrel = parse_pred vrel in
    let vtopo = parse_pol vtopo in
    let ving_pol = parse_pol ving_pol in
    let ving = parse_pred ving in
    let veg = parse_pred veg in
    let ptopo = parse_pol ptopo in
    let ping = parse_pred ping in
    let peg = parse_pred peg in

    (* compile *)
    let module Virtual = Frenetic_NetKAT_Virtual_Compiler in
    let global_pol =
      Virtual.compile vpol ~log:true ~vrel ~vtopo ~ving_pol ~ving ~veg ~ptopo ~ping ~peg
    in
    let fdd = Frenetic_NetKAT_Compiler.compile_global global_pol in

    (* print & dump *)
    let switches = Frenetic_NetKAT_Semantics.switches_of_policy global_pol in
    if printglobal then begin
      Format.fprintf fmt "Global Policy:@\n@[%a@]@\n@\n"
        Frenetic_NetKAT_Pretty.format_policy global_pol
    end;
    if printfdd then print_fdd fdd;
    if dumpfdd then dump_fdd fdd;
    print_all_tables fdd switches

end



(*===========================================================================*)
(* BASIC SPECIFICATION OF COMMANDS                                           *)
(*===========================================================================*)

let local : Command.t =
  Command.basic
    ~summary:"Runs local compiler and dumps resulting tables."
    (* ~readme: *)
    Local.spec
    Local.run

let global : Command.t =
  Command.basic
    ~summary:"Runs global compiler and dumps resulting tables."
    (* ~readme: *)
    Global.spec
    Global.run

let virt : Command.t =
  Command.basic
    ~summary:"Runs virtual compiler and dumps resulting tables."
    (* ~readme: *)
    Virtual.spec
    Virtual.run

let main : Command.t =
  Command.group
    ~summary:"Runs (local/global/virtual) compiler and dumps resulting tables."
    (* ~readme: *)
    [("local", local); ("global", global); ("virtual", virt)]
