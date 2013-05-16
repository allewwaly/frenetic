open Misc
open OpenFlow0x01.Types
open Packet.Types
open Printf
open Syntax

(* Internal policy type *)
type pol = NetCoreEval.pol

let (<&>) = Lwt.(<&>)

let init_pol : pol = NetCoreEval.PoFilter NetCoreEval.PrNone

let for_bucket (in_port : portId) (pkt : NetCoreEval.value) =
  let open NetCoreEval in
  match pkt with
  | Pkt (swId, Pattern.Bucket n, pkt, _) -> Some (n, swId, in_port, pkt)
  | _ -> None

module Make (Platform : OpenFlow0x01.PLATFORM) = struct

  let get_pkt_handlers : (int, get_packet_handler) Hashtbl.t = 
    Hashtbl.create 200

  let apply_bucket (bucket_id, sw, pt, pk) : unit =
    let handler = Hashtbl.find get_pkt_handlers bucket_id in
    handler sw pt pk

  (* used to initialize newly connected switches and handle packet-in 
     messages *)
  let pol_now : pol ref = ref init_pol

  let configure_switch (sw : switchId) (pol : pol) : unit Lwt.t =
    let flow_table = NetCoreCompiler.flow_table_of_policy sw pol in
    Platform.send_to_switch sw 0l delete_all_flows >>
    Lwt_list.iter_s
      (fun (match_, actions) ->
          Platform.send_to_switch sw 0l (add_flow match_ actions))
      flow_table

  let install_new_policies sw pol_stream =
    Lwt_stream.iter_s (configure_switch sw) pol_stream
      
  let handle_packet_in sw pkt_in = 
    let open NetCoreEval in
    match pkt_in.packetInBufferId with
      | None -> Lwt.return ()
      | Some bufferId ->
        let inp = Pkt (sw, Pattern.Physical pkt_in.packetInPort,
                       pkt_in.packetInPacket, Misc.Inl bufferId ) in
        let outs = classify !pol_now inp in
        let for_buckets = filter_map (for_bucket pkt_in.packetInPort) outs in
        List.iter apply_bucket for_buckets;
        Lwt.return ()

  let rec handle_switch_messages sw = 
    lwt v = Platform.recv_from_switch sw in
    match v with
      | (_, PacketInMsg pktIn) ->
        handle_packet_in sw pktIn >> handle_switch_messages sw
      | _ -> handle_switch_messages sw

  let switch_thread
      (sw : switchId)
      (init_pol : pol)
      (pol_stream : pol Lwt_stream.t) = 
    configure_switch sw init_pol >>
    install_new_policies sw pol_stream <&> handle_switch_messages sw

  let rec accept_switches pol_stream = 
    lwt features = Platform.accept_switch () in
    Log.printf "[NetCore_Controller.ml]: switch %Ld connected\n"
      features.switch_id;
    let switch = switch_thread features.switch_id 
      !pol_now (Lwt_stream.clone pol_stream) in
    switch <&> accept_switches pol_stream

  let bucket_cell = ref 0 
  let vlan_cell = ref 0 
  let genbucket () = 
    incr bucket_cell;
    !bucket_cell
  let genvlan () = 
    incr vlan_cell;
    Some !vlan_cell

  let configure_switches push_pol sugared_pol_stream =
    Lwt_stream.iter
      (fun pol ->
        let p = Syntax.desugar genbucket genvlan pol get_pkt_handlers in
        pol_now := p;
        push_pol (Some p))
      sugared_pol_stream

  let start_controller (pol : policy Lwt_stream.t) : unit Lwt.t = 
    let (pol_stream, push_pol) = Lwt_stream.create () in
    accept_switches pol_stream <&> configure_switches push_pol pol

end
