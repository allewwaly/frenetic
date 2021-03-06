(* TODO: Currently Unused.  See Frenetic_OpenFlow0x01_Controller for Future Directions *)

open Core.Std
open Async.Std

module OF10 = Frenetic_OpenFlow0x01
module M = OF10.Message
module Net = Frenetic_NetKAT_Net.Net
module SDN = Frenetic_OpenFlow
module Log = Frenetic_Log
module Controller = Frenetic_OpenFlow0x01_Controller
module Comp = Frenetic_NetKAT_Compiler

exception UpdateError

module SwitchMap = Map.Make(struct
  type t = Frenetic_OpenFlow.switchId [@@deriving sexp]
  let compare = compare
end)

type edge = (Frenetic_OpenFlow.flow * int) list SwitchMap.t

module type UPDATE_ARGS = sig
  val get_order : unit -> Comp.order
  val get_prev_order : unit -> Comp.order
end

module type CONSISTENT_UPDATE_ARGS = sig
  val get_order : unit -> Comp.order
  val get_prev_order : unit -> Comp.order
  val get_nib : unit -> Net.Topology.t
  val get_edge : unit -> edge
  val set_edge : edge -> unit
end

module type UPDATE = sig
  val bring_up_switch :
    SDN.switchId ->
    Comp.t ->
    unit Deferred.t

  val implement_policy :
    Comp.t ->
    unit Deferred.t

  val set_current_compiler_options : Comp.compiler_options -> unit
end

module BestEffortUpdate = struct
  open Frenetic_OpenFlow.To0x01

  let current_compiler_options =
    ref Comp.default_compiler_options

  let restrict sw_id repr =
    Comp.restrict Frenetic_NetKAT.(Switch sw_id) repr

  let install_flows_for sw_id table =
    let to_flow_mod p f = M.FlowModMsg (from_flow p f) in
    let priority = ref 65536 in
    let flows = List.map table ~f:(fun flow ->
        decr priority;
        to_flow_mod !priority flow) in
    Controller.send_batch sw_id 0l flows >>= function
    | `Eof -> raise UpdateError
    | `Ok -> return ()

  let delete_flows_for sw_id =
    let delete_flows = M.FlowModMsg OF10.delete_all_flows in
    Controller.send sw_id 5l delete_flows >>= function
      | `Eof -> raise UpdateError
      | `Ok -> return ()

  let bring_up_switch (sw_id : SDN.switchId) new_r =
    let table = Comp.to_table ~options:!current_compiler_options sw_id new_r in
    Log.printf ~level:`Debug "Setting up flow table\n%s"
      (Frenetic_OpenFlow.string_of_flowTable ~label:(Int64.to_string sw_id) table);
    Monitor.try_with ~name:"BestEffort.bring_up_switch" (fun () ->
      delete_flows_for sw_id >>= fun _ ->
      install_flows_for sw_id table)
    >>= function
      | Ok x -> return x
      | Error _exn ->
        Log.debug
          "switch %Lu: disconnected while attempting to bring up... skipping" sw_id;
        Log.flushed () >>| fun () ->
        Log.error "%s\n%!" (Exn.to_string _exn)

  let implement_policy repr =
    (Controller.get_switches ()) >>= fun switches ->
    Deferred.List.iter switches (fun sw_id ->
      bring_up_switch sw_id repr)

  let set_current_compiler_options opt =
    current_compiler_options := opt
end

module PerPacketConsistent (Args : CONSISTENT_UPDATE_ARGS) : UPDATE = struct
  open Frenetic_OpenFlow
  open To0x01
  open Args

  let current_compiler_options = ref Comp.default_compiler_options

  let barrier sw =
    Controller.send_txn sw M.BarrierRequest >>= function
      | `Ok dl -> return (Ok ())
      | `Eof -> return (Error UpdateError)

  let install_flows_for sw_id table =
    let to_flow_mod p f = M.FlowModMsg (from_flow p f) in
    let priority = ref 65536 in
    let flows = List.map table ~f:(fun flow ->
        decr priority;
        to_flow_mod !priority flow) in
    Controller.send_batch sw_id 0l flows >>= function
    | `Eof -> raise UpdateError
    | `Ok -> return ()

  let delete_flows_for sw_id =
    let delete_flows = M.FlowModMsg OF10.delete_all_flows in
    Controller.send sw_id 5l delete_flows >>= function
      | `Eof -> raise UpdateError
      | `Ok -> return ()

  let specialize_action ver internal_ports actions =
    List.fold_right actions ~init:[] ~f:(fun action acc ->
      begin match action with
      | Output (Physical   pt) ->
        if not (Net.Topology.PortSet.mem internal_ports pt) then
          [Modify (SetVlan None)]
        else
          [Modify (SetVlan (Some ver))]
      | Output (Controller n ) ->
        [Modify (SetVlan None)]
      | Output _               -> assert false
      | _                      -> acc
      end @ (action :: acc))

  let specialize_edge_to (ver : int) internal_ports (table : SDN.flowTable) =
    let vlan_none = 65535 in
    List.filter_map table ~f:(fun flow ->
      begin match flow.pattern.Pattern.inPort with
      | Some pt when Net.Topology.PortSet.mem internal_ports pt ->
        None
      | _ ->
        Some { flow with
          pattern = { flow.pattern with Pattern.dlVlan = Some vlan_none }
        ; action  = List.map flow.action ~f:(fun x ->
            List.map x ~f:(specialize_action ver internal_ports))
        }
      end)

  let specialize_internal_to (ver : int) internal_ports (table : SDN.flowTable) =
    List.map table ~f:(fun flow ->
      { flow with
        pattern = { flow.pattern with Pattern.dlVlan = Some ver }
      ; action  = List.map flow.action ~f:(fun x ->
          List.map x ~f:(specialize_action ver internal_ports))
      })

  let clear_policy_for (ver : int) sw_id =
    let open OF10 in
    let clear_rule = { pattern = { Pattern.match_all with Pattern.dlVlan = Some ver }
      ; action = []
      ; cookie = 0L
      ; idle_timeout = Permanent
      ; hard_timeout = Permanent
    } in
    let clear_version_message = M.FlowModMsg ( {(from_flow 0 clear_rule) with command = DeleteFlow} ) in
    Monitor.try_with ~name:"PerPacketConsistent.clear_policy_for" (fun () ->
      Controller.send sw_id 5l clear_version_message >>= function
        | `Eof -> raise UpdateError
        | `Ok -> return ())
    >>| function
      | Ok (_)    -> ()
      | Error _exn ->
        Log.error "switch %Lu: Failed to delete flows for ver %d" sw_id ver

  let internal_install_policy_for (ver : int) repr (sw_id : switchId) =
    begin let open Deferred.Result in
    Monitor.try_with ~name:"PerPacketConsistent.internal_install_policy_for" (fun () ->
      let table0 = Comp.to_table sw_id repr in
      let table1 = specialize_internal_to
        ver (Frenetic_Topology.internal_ports (get_nib ()) sw_id) table0 in
      assert (List.length table1 > 0);
      install_flows_for  sw_id table1)
    >>= fun () -> barrier sw_id
    end
    >>| function
      | Ok () ->
        Log.debug
          "switch %Lu: installed internal table for ver %d" sw_id ver;
      | Error _ ->
        Log.debug
          "switch %Lu: disconnected while installing internal table for ver %d... skipping" sw_id ver

  (* Comparison should be made based on patterns only, not actions *)
  (* Assumes both FT are sorted in descending order by priority *)
  let rec flowtable_diff (ft1 : (Frenetic_OpenFlow.flow*int) list) (ft2 : (Frenetic_OpenFlow.flow*int) list) =
    let open Frenetic_OpenFlow in
    match ft1,ft2 with
    | (flow1,pri1)::ft1, (flow2,pri2)::ft2 ->
      if pri1 > pri2 then
        (flow1, pri1) :: flowtable_diff ft1 ((flow2,pri2)::ft2)
      else if pri1 = pri2 && flow1.pattern = flow2.pattern then
        flowtable_diff ft1 ((flow2,pri2)::ft2)
      else
        flowtable_diff ((flow1,pri1) :: ft1) ft2
    | _, [] -> ft1
    | [], _ -> []

  (* Assumptions:
     - switch respects priorities when deleting flows
  *)
  let swap_update_for sw_id c_id new_table : unit Deferred.t =
    let open OF10 in
    let max_priority = 65535 in
    let old_table = match SwitchMap.find (get_edge ()) sw_id with
      | Some ft -> ft
      | None -> [] in
    let (new_table, _) = List.fold new_table ~init:([], max_priority)
        ~f:(fun (acc,pri) x -> ((x,pri) :: acc, pri - 1)) in
    let new_table = List.rev new_table in
    let del_table = List.rev (flowtable_diff old_table new_table) in
    let to_flow_mod prio flow =
      M.FlowModMsg (from_flow prio flow) in
    let to_flow_del prio flow =
      M.FlowModMsg ({(from_flow prio flow) with command = DeleteStrictFlow}) in
    (* Install the new table *)
    let new_flows = List.map new_table ~f:(fun (flow, prio) ->
        to_flow_mod prio flow) in
    Controller.send_batch c_id 0l new_flows >>= function
        | `Eof -> raise UpdateError
        | `Ok -> return ()
    (* Delete the old table from the bottom up *)
    >>= fun () -> Deferred.List.iter del_table ~f:(fun (flow, prio) ->
      Controller.send c_id 0l (to_flow_del prio flow) >>= function
        | `Eof -> raise UpdateError
        | `Ok -> return ())
    >>| fun () ->
    set_edge (SwitchMap.add (get_edge ()) sw_id new_table)

  let edge_install_policy_for ver repr (sw_id : switchId) : unit Deferred.t =
    begin let open Deferred.Result in
    Monitor.try_with ~name:"PerPacketConsistent.edge_install_policy_for" (fun () ->
      let table = Comp.to_table sw_id repr in
      let edge_table = specialize_edge_to
        ver (Frenetic_Topology.internal_ports (get_nib ()) sw_id) table in
      Log.debug
        "switch %Lu: Installing edge table for ver %d" sw_id ver;
      swap_update_for sw_id sw_id edge_table)
    >>= fun () -> barrier sw_id
    end
    >>| function
      | Ok () ->
        Log.debug "switch %Lu: installed edge table for ver %d" sw_id ver
      | Error _ ->
        Log.debug "switch %Lu: disconnected while installing edge table for ver %d... skipping" sw_id ver

  let ver = ref 1

  let implement_policy repr : unit Deferred.t =
    (* XXX(seliopou): It might be better to iterate over client ids rather than
     * switch ids. A client id is guaranteed to be unique within a run of a
     * program, whereas a switch id may be reused across client ids, i.e., a
     * switch connects, disconnects, and connects again. Due to this behavior,
     * it may be possible to get into an inconsistent state below. Maybe. *)
    Controller.get_switches () >>= fun switches ->
    let ver_num = !ver + 1 in
    (* Install internal update *)
    Log.debug "Installing internal tables for ver %d" ver_num;
    Log.flushed ()
    >>= fun () ->
    Deferred.List.iter switches (internal_install_policy_for ver_num repr)
    >>= fun () ->
    (Log.debug "Installing edge tables for ver %d" ver_num;
     Log.flushed ())
    >>= fun () ->
    (* Install edge update *)
    Deferred.List.iter switches (edge_install_policy_for ver_num repr)
    >>= fun () ->
    (* Delete old rules *)
    Deferred.List.iter switches (clear_policy_for (ver_num - 1))
    >>| fun () ->
      incr ver

  let bring_up_switch (sw_id : switchId) repr =
    Monitor.try_with ~name:"PerPacketConsistent.bring_up_switch" (fun () ->
      delete_flows_for sw_id >>= fun () ->
      internal_install_policy_for !ver repr sw_id >>= fun () ->
      edge_install_policy_for !ver repr sw_id)
    >>= function
      | Ok x -> return ()
      | Error _exn ->
        Log.debug
          "switch %Lu: disconnected while attempting to bring up... skipping" sw_id;
        Log.flushed () >>| fun () ->
        Log.error "%s\n%!" (Exn.to_string _exn)

  let set_current_compiler_options opt =
    current_compiler_options := opt

end
