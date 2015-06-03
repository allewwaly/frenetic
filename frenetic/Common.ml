open Core.Std
open Async.Std
open Cohttp_async
open NetKAT_Types


let rec virtualize_pred pred =
  match pred with
  | True -> True
  | False -> False
  | Test (Switch sw) -> Test (VSwitch sw)
  | Test (Location (Physical pt)) -> Test (VPort (Int64.of_int32 pt))
  | Test hv -> Test hv
  | And (a, b) -> And (virtualize_pred a, virtualize_pred b)
  | Or (a, b) -> Or (virtualize_pred a, virtualize_pred b)
  | Neg a -> Neg (virtualize_pred a)

let rec virtualize_pol pol =
  match pol with
  | Filter pred -> Filter (virtualize_pred pred)
  | Mod (Location (Physical pt)) -> Mod (VPort (Int64.of_int32 pt))
  | Union (p, q) -> Union (virtualize_pol p, virtualize_pol q)
  | Seq (p, q) -> Seq (virtualize_pol p, virtualize_pol q)
  | Star p -> Star (virtualize_pol p)
  | _ -> assert false


let printf ?(level : [ `Debug | `Info | `Error ] = `Info)
  (fmt :  ('a, unit, string, unit) format4) =
  Async_OpenFlow.Log.printf ~level ~tags:[("frenetic", "http")] fmt

(* Extract the path, split on slashes, and remove empty strings caused by
   repeated slashes *)
let extract_path (req : Request.t) : string list =
    List.filter ~f:(fun str -> not (String.is_empty str))
      (String.split ~on:'/'
         (Uri.path req.uri))

(* Note: cannot create a variable called parser because of some Camlp4 thing
   we are using. *)
let handle_parse_errors
  (body : Cohttp_async.Body.t)
  (body_parser : Cohttp_async.Body.t -> 'a Deferred.t)
  (handler : 'a -> Cohttp_async.Server.response Deferred.t) :
  Cohttp_async.Server.response Deferred.t =
  try_with (fun () -> body_parser body)
  >>= function
  | Ok x -> handler x
  | Error exn ->
      printf ~level:`Error "Invalid message from client";
      Cohttp_async.Server.respond `Bad_request

let parse_update body = Body.to_string body >>= fun pol_str ->
  let lexbuf = Lexing.from_string pol_str in
  let pol = NetKAT_Parser.program NetKAT_Lexer.token lexbuf in
  return pol

let parse_update_json body =
  Body.to_string body >>= fun str ->
  return (NetKAT_Json.policy_from_json_string str)
