open Core.Std
open Async.Std
open Log.Global

open Bs_devkit.Core
module BMEX = Bitmex_api
module BFX = Bfx_api
module PLNX = Poloniex_api

let default_cfg = Filename.concat (Option.value_exn (Sys.getenv "HOME")) ".virtu"
let find_auth cfg exchange =
  let cfg_json = Yojson.Safe.from_file cfg in
  let cfg = Result.ok_or_failwith @@ Cfg.of_yojson cfg_json in
  let { Cfg.key; secret } = List.Assoc.find_exn cfg exchange in
  key, Cstruct.of_string secret

let base_spec =
  let open Command.Spec in
  empty
  +> flag "-cfg" (optional_with_default default_cfg string) ~doc:"path Filepath of cfg (default: ~/.virtu)"
  +> flag "-loglevel" (optional int) ~doc:"1-3 loglevel"
  +> flag "-testnet" no_arg ~doc:" Use testnet"
  +> flag "-md" no_arg ~doc:" Use multiplexing"
  +> anon (sequence ("topic" %: string))

let bitmex key secret testnet md topics =
  let buf = Bi_outbuf.create 4096 in
  let to_ws = Pipe.map Reader.(stdin |> Lazy.force |> pipe) ~f:(Yojson.Safe.from_string ~buf) in
  let r = BMEX.Ws.open_connection ~buf ~to_ws ~log:Lazy.(force log) ~auth:(key, secret) ~testnet ~topics ~md () in
  Pipe.transfer r Writer.(pipe @@ Lazy.force stderr) ~f:(fun s -> Yojson.Safe.to_string ~buf s ^ "\n")

let bitmex =
  let run cfg loglevel testnet md topics =
    let exchange = "BMEX" ^ (if testnet then "T" else "") in
    let key, secret = find_auth cfg exchange in
    Option.iter loglevel ~f:(Fn.compose set_level loglevel_of_int);
    don't_wait_for @@ bitmex key secret testnet md topics;
    never_returns @@ Scheduler.go ()
  in
  Command.basic ~summary:"BitMEX WS client" base_spec run

let kaiko topics =
  let open BMEX.Ws.Kaiko in
  let buf = Bi_outbuf.create 4096 in
  let r = tickers ~log:Lazy.(force log) topics in
  Pipe.transfer r Writer.(pipe @@ Lazy.force stderr) ~f:begin fun data ->
    let json = data_to_yojson data  in
    Yojson.Safe.to_string ~buf json ^ "\n"
  end

let kaiko =
  let run _cfg loglevel _testnet _md topics =
    Option.iter loglevel ~f:(Fn.compose set_level loglevel_of_int);
    don't_wait_for @@ kaiko topics;
    never_returns @@ Scheduler.go ()
  in
  Command.basic ~summary:"Kaiko WS client" base_spec run

let bfx key secret topics =
  let open BFX.Ws in
  let evts = List.map topics ~f:begin fun ts -> match String.split ts ~on:':' with
    | [topic; symbol] ->
      BFX.Ws.Ev.create ~name:"subscribe" ~fields:["channel", `String topic; "pair", `String symbol; "prec", `String "R0"] ()
    | _ -> invalid_arg "topic"
    end
  in
  let buf = Bi_outbuf.create 4096 in
  let to_ws, to_ws_w = Pipe.create () in
  let r = open_connection ~to_ws ~buf ~auth:(key, secret) () in
  Pipe.transfer' r Writer.(pipe @@ Lazy.force stderr) ~f:begin fun q ->
    Deferred.Queue.filter_map q ~f:begin fun s ->
      Result.iter (Ev.of_yojson s) ~f:begin function
      | { name = "info" } -> don't_wait_for @@ Pipe.(transfer_id (of_list evts) to_ws_w);
      | _ -> ()
      end;
      return @@ Option.some @@ Yojson.Safe.to_string ~buf s ^ "\n"
    end
  end

let bfx =
  let run cfg loglevel _testnet _md topics =
    let key, secret = find_auth cfg "BFX" in
    Option.iter loglevel ~f:(Fn.compose set_level loglevel_of_int);
    don't_wait_for @@ bfx key secret topics;
    never_returns @@ Scheduler.go ()
  in
  Command.basic ~summary:"Bitfinex WS client" base_spec run

let plnx topics =
  let to_ws, to_ws_w = Pipe.create () in
  let r = PLNX.Ws.open_connection ~log:(Lazy.force log) to_ws in
  let transfer_f q =
    Deferred.Queue.filter_map q ~f:begin function
    | Wamp.Welcome _ as msg ->
      PLNX.Ws.Msgpck.subscribe to_ws_w topics >>| fun _req_ids ->
      msg |> Wamp_msgpck.msg_to_msgpck |>
      Msgpck.sexp_of_t |> fun msg_str ->
      Option.some @@ Sexplib.Sexp.to_string_hum msg_str ^ "\n";
    | msg ->
      msg |> Wamp_msgpck.msg_to_msgpck |>
      Msgpck.sexp_of_t |> fun msg_str ->
      return @@ Option.some @@ Sexplib.Sexp.to_string_hum msg_str ^ "\n";
    end
  in
  Pipe.transfer' r Writer.(pipe @@ Lazy.force stderr) ~f:transfer_f

let plnx =
  let run cfg loglevel _testnet _md topics =
    Option.iter loglevel ~f:(Fn.compose set_level loglevel_of_int);
    don't_wait_for @@ plnx topics;
    never_returns @@ Scheduler.go ()
  in
  Command.basic ~summary:"Poloniex WS client" base_spec run

let plnx_trades currency =
  let open PLNX in
  let r = Rest.all_trades ~log:(Lazy.force log) currency in
  let transfer_f t = DB.sexp_of_trade t |> Sexplib.Sexp.to_string |> fun s -> s ^ "\n" in
  Pipe.transfer r Writer.(pipe @@ Lazy.force stderr) ~f:transfer_f >>= fun () ->
  Shutdown.exit 0

let plnx_trades =
  let run cfg loglevel _testnet _md topics =
    Option.iter loglevel ~f:(Fn.compose set_level loglevel_of_int);
    begin match topics with
    | [] -> invalid_arg "topics"
    | currency :: _ -> don't_wait_for @@ plnx_trades currency;
    end;
    never_returns @@ Scheduler.go ()
  in
  Command.basic ~summary:"Poloniex trades" base_spec run

let command =
  Command.group ~summary:"Exchanges WS client"
    [
      "bitmex", bitmex;
      "bfx", bfx;
      "plnx", plnx;
      "plnx-trades", plnx_trades;
      "kaiko", kaiko;
    ]

let () = Command.run command

