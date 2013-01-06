Set Implicit Arguments.

Require Import Coq.Lists.List.
Require Import Coq.Classes.Equivalence.
Require Import Coq.Structures.Equalities.
Require Import Coq.Classes.Morphisms.
Require Import Coq.Setoids.Setoid.
Require Import Common.Types.
Require Import Common.Bisimulation.
Require Import Bag.Bag.
Require Import FwOF.FwOF.

Local Open Scope list_scope.
Local Open Scope equiv_scope.
Local Open Scope bag_scope.

Module Make (Import Atoms : ATOMS).

  Module Concrete := ConcreteSemantics (Atoms).
  Import Concrete.

  Axiom topo : switchId * portId -> option (switchId * portId).

  Definition abst_state := Bag.bag (switchId * portId * packet).

  Axiom relate_controller : controller -> abst_state.

  Axiom abst_func : switchId -> portId -> packet -> list (portId * packet).

  Definition affixSwitch (sw : switchId) (ptpk : portId * packet) :=
    match ptpk with
      | (pt,pk) => (sw,pt,pk)
    end.

  Definition transfer (sw : switchId) (ptpk : portId * packet) :=
    match ptpk with
      | (pt,pk) =>
        match topo (sw,pt) with
          | Some (sw',pt') => {| (sw',pt',pk) |}
          | None => {| |}
        end
    end.

  Definition select_packet_out (sw : switchId) (msg : fromController) :=
    match msg with
      | PacketOut pt pk => transfer sw (pt,pk)
      | _ => {| |}
    end.

  Axiom locate_packet_in : switchId -> portId -> packet -> 
    list (portId * packet).

  Definition select_packet_in (sw : switchId) (msg : fromSwitch) :=
    match msg with
      | PacketIn pt pk => 
        Bag.FromList (map (affixSwitch sw) (locate_packet_in sw pt pk))
      | _ => {| |}
    end.

  Definition FlowTableSafe (sw : switchId) (tbl : flowTable) : Prop :=
    forall pt pk forwardedPkts packetIns,
      process_packet tbl pt pk = (forwardedPkts, packetIns) ->
      Bag.unions (map (transfer sw) forwardedPkts) <+>
      Bag.unions (map (select_packet_in sw) (map (PacketIn pt) packetIns)) ===
      Bag.unions (map (transfer sw) (abst_func sw pt pk)).

  Definition FlowTablesSafe (st : state) : Prop :=
    forall swId pts tbl inp outp ctrlm switchm,
      In (Switch swId pts tbl inp outp ctrlm switchm) (switches st) ->
      FlowTableSafe swId tbl.

  Definition ConsistentDataLinks (st : state) : Prop :=
    forall (lnk : dataLink),
      In lnk (links st) ->
      topo (src lnk) = Some (dst lnk).

  Axiom ControllerRemembersPackets :
    forall (ctrl ctrl' : controller),
      controller_step ctrl ctrl' ->
      relate_controller ctrl = relate_controller ctrl'.

  Axiom ControllerSendForgetsPackets : forall ctrl ctrl' sw msg,
    controller_send ctrl ctrl' sw msg ->
    relate_controller ctrl === select_packet_out sw msg <+>
    relate_controller ctrl'.

  Axiom ControllerRecvRemembersPackets : forall ctrl ctrl' sw msg,
    controller_recv ctrl sw msg ctrl' ->
    relate_controller ctrl' === select_packet_in sw msg <+> 
    (relate_controller ctrl).

  Definition LinksHaveSrc (st : state) : Prop :=
    forall src_sw src_pt dst pks,
      In (DataLink (src_sw,src_pt) pks dst) (links st) ->
      (exists switch, 
        In switch (switches st) /\
        src_sw = swId switch /\
        In src_pt (pts switch)).

  Definition LinksHaveDst (st : state) : Prop :=
    forall dst_sw dst_pt src pks,
      In (DataLink src pks (dst_sw,dst_pt)) (links st) ->
      (exists switch, 
        In switch (switches st) /\
        dst_sw = swId switch /\
        In dst_pt (pts switch)).

    
  Record concreteState := ConcreteState {
    devices : state;
    concreteState_flowTableSafety : 
      FlowTablesSafe devices;
    concreteState_consistentDataLinks :
      ConsistentDataLinks devices;
    linksHaveSrc : LinksHaveSrc devices;
    dstLinksExist : LinksHaveDst devices
  }.

  Implicit Arguments ConcreteState [].

  Definition concreteStep (st : concreteState) (obs : option observation)
    (st0 : concreteState) :=
    step (devices st) obs (devices st0).

  Inductive abstractStep : abst_state -> option observation -> abst_state -> 
    Prop := 
  | AbstractStepEquiv : forall st st',
      st === st' ->
      abstractStep st None st'
  | AbstractStep : forall sw pt pk lps,
    abstractStep
      ({| (sw,pt,pk) |} <+> lps)
      (Some (sw,pt,pk))
      (Bag.unions (map (transfer sw) (abst_func sw pt pk)) <+> lps).

  Definition relate_switch (sw : switch) : abst_state :=
    match sw with
      | Switch swId _ tbl inp outp ctrlm switchm =>
        Bag.FromList (map (affixSwitch swId) (Bag.to_list inp)) <+>
        Bag.unions (map (transfer swId) (Bag.to_list outp)) <+>
        Bag.unions (map (select_packet_out swId) (Bag.to_list ctrlm)) <+>
        Bag.unions (map (select_packet_in swId) (Bag.to_list switchm))
    end.

  Definition relate_dataLink (link : dataLink) : abst_state :=
    match link with
      | DataLink _ pks (sw,pt) =>
        Bag.FromList (map (fun pk => (sw,pt,pk)) pks)
    end.

  Definition relate_openFlowLink (link : openFlowLink) : abst_state :=
    match link with
      | OpenFlowLink sw switchm ctrlm =>
        Bag.unions (map (select_packet_out sw) ctrlm) <+>
        Bag.unions (map (select_packet_in sw) switchm)
    end.


  Definition relate (st : state) : abst_state :=
    Bag.unions (map relate_switch (switches st)) <+>
    Bag.unions (map relate_dataLink (links st)) <+>
    Bag.unions (map relate_openFlowLink (ofLinks st)) <+>
    relate_controller (ctrl st).

  Definition bisim_relation : relation concreteState abst_state :=
    fun (st : concreteState) (ast : abst_state) => 
      ast === (relate (devices st)).

End Make.



(*
  Theorem fwof_abst_weak_bisim :
    weak_bisimulation concreteStep abstractStep bisim_relation.
  Proof.
    unfold weak_bisimulation.
    split.
    exact weak_sim_1.
    exact weak_sim_2.
  Qed.

End Make.    
  
*)  
