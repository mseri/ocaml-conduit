(*
 * Copyright (c) 2014 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Lwt
open Sexplib.Std

IFDEF HAVE_VCHAN THEN
type vchan_port = Vchan.Port.t with sexp
ELSE
type vchan_port = [ `Vchan_not_available ] with sexp
ENDIF

type client = [
  | `TCP of Ipaddr.t * int
  | `Vchan of int * vchan_port
] with sexp

type server = [
  | `TCP of [ `Port of int ]
  | `Vchan of int * vchan_port
] with sexp

type unknown = [ `Unknown of string ]

module type ENDPOINT = sig
  type t with sexp_of
  type port = vchan_port

  type error = [
    `Unknown of string
  ]

  val server :
    domid:int ->
    port:port ->
    ?read_size:int ->
    ?write_size:int ->
    unit -> t Lwt.t

  val client :
    domid:int ->
    port:port ->
    unit -> t Lwt.t

  val close : t -> unit Lwt.t
  (** Close a vchan. This deallocates the vchan and attempts to free
      its resources. The other side is notified of the close, but can
      still read any data pending prior to the close. *)

  include V1_LWT.FLOW
    with type flow = t
    and  type error := error
    and  type 'a io = 'a Lwt.t
    and  type buffer = Cstruct.t
end

(** All the possible connection types supported *)
module Make_flow(S:V1_LWT.TCPV4)(V: ENDPOINT) =
struct

  type 'a io = 'a Lwt.t
  type error = [ `Refused | `Timeout | `Unknown of string ]

  type buffer = Cstruct.t

  type flow =
    | TCPv4 of S.flow
    | Vchan of V.flow

  let of_tcpv4 f = TCPv4 f
  let of_vchan f = Vchan f

  let vchan_error t =
    t >>= function
      | `Error (`Unknown x) -> return (`Error (`Unknown x))
      | `Eof -> return (`Eof)
      | `Ok b -> return (`Ok b)

  let stack_error t =
    t >>= function
      | `Error (`Unknown x) -> return (`Error (`Unknown x))
      | `Error (`Refused) -> return (`Error (`Refused))
      | `Error (`Timeout) -> return (`Error (`Timeout))
      | `Eof -> return (`Eof)
      | `Ok b -> return (`Ok b)

  let read flow =
    match flow with
    | Vchan t -> vchan_error (V.read t)
    | TCPv4 t -> stack_error (S.read t)

  let write flow buf =
    match flow with
    | Vchan t -> vchan_error (V.write t buf)
    | TCPv4 t -> stack_error (S.write t buf)

  let writev flow bufv =
    match flow with
    | Vchan t -> vchan_error (V.writev t bufv)
    | TCPv4 t -> stack_error (S.writev t bufv)

  let close flow =
    match flow with
    | Vchan t -> V.close t
    | TCPv4 t -> S.close t
end

module Make(S:V1_LWT.STACKV4)(V: ENDPOINT) = struct

  module Flow = Make_flow(S.TCPV4)(V)
  type +'a io = 'a Lwt.t
  type ic = Flow.flow
  type oc = Flow.flow
  type flow = Flow.flow
  type stack = S.t

  type ctx = {
    stack: S.t option;
  }

  let init stack =
    return { stack = Some stack }

  let default_ctx =
    { stack = None  }

  let connect ~ctx mode =
    match mode, ctx.stack with
    | `Vchan (domid, port), _ ->
      V.client ~domid ~port ()
      >>= fun flow ->
      let flow = Flow.of_vchan flow in
      return (flow, flow, flow)
    | `TCP (Ipaddr.V6 _ip, _port), _ ->
      fail (Failure "No IPv6 support compiled into Conduit")
    | `TCP (Ipaddr.V4 _ip, _port), None ->
      fail (Failure "No stack bound to Conduit")
    | `TCP (Ipaddr.V4 ip, port), Some tcp  ->
      S.TCPV4.create_connection (S.tcpv4 tcp) (ip,port) >>= function
      | `Error _err -> fail (Failure "connection failed")
      | `Ok flow ->
        let flow = Flow.of_tcpv4 flow in
        return (flow, flow, flow)

  let serve ?(timeout=60) ?stop:_ ~ctx ~mode fn =
    let _ = timeout in
    let t, _u = Lwt.task () in
    Lwt.on_cancel t (fun () -> print_endline "Stopping server thread");
    match mode, ctx.stack with
    |`TCP (`Port _port), None ->
      fail (Failure "No stack bound to Conduit")
    |`TCP (`Port port), Some stack ->
      S.listen_tcpv4 stack ~port
        (fun flow ->
           let f = Flow.of_tcpv4 flow in
           fn f f f
        );
      t
    |`Vchan (domid, port), _ ->
      V.server ~domid ~port ()
      >>= fun t ->
      let f = Flow.of_vchan t in
      fn f f f

  let endp_to_client ~ctx:_ (endp:Conduit.endp) : client Lwt.t =
    match endp with
    | `TCP (_ip, _port) as mode -> return mode
    | `Vchan (domid, port) ->
IFDEF HAVE_VCHAN THEN
       begin
         match Vchan.Port.of_string port with 
         | `Error s -> fail (Failure ("Invalid vchan port: " ^ s))
         | `Ok p -> return p
       end >>= fun port ->
       return (`Vchan (domid, port))
ELSE
       fail (Failure "Vchan not available")
ENDIF
    | `Unix_domain_socket _path -> fail (Failure "Domain sockets not valid on Mirage")
    | `TLS (_host, _) -> fail (Failure "TLS currently unsupported")
    | `Unknown err -> fail (Failure ("resolution failed: " ^ err))

  let endp_to_server ~ctx:_ (endp:Conduit.endp) : server Lwt.t =
    match endp with
    | `TCP (_ip, port) -> return (`TCP (`Port port))
    | `Vchan (domid, port) ->
IFDEF HAVE_VCHAN THEN
       begin
         match Vchan.Port.of_string port with 
         | `Error s -> fail (Failure ("Invalid vchan port: " ^ s))
         | `Ok p -> return p
       end >>= fun port ->
       return (`Vchan (domid, port))
ELSE
       fail (Failure "Vchan not available")
ENDIF
    | `Unix_domain_socket _path -> fail (Failure "Domain sockets not valid on Mirage")
    | `TLS (_host, _) -> fail (Failure "TLS currently unsupported")
    | `Unknown err -> fail (Failure ("resolution failed: " ^ err))
end

module type S = sig

  module Flow : V1_LWT.FLOW
  type +'a io = 'a Lwt.t
  type ic = Flow.flow
  type oc = Flow.flow
  type flow = Flow.flow
  type stack

  type ctx
  val default_ctx : ctx

  val init : stack -> ctx io

  val connect : ctx:ctx -> client -> (flow * ic * oc) io

  val serve :
    ?timeout:int -> ?stop:(unit io) -> ctx:ctx ->
     mode:server -> (flow -> ic -> oc -> unit io) -> unit io

  val endp_to_client: ctx:ctx -> Conduit.endp -> client io
  val endp_to_server: ctx:ctx -> Conduit.endp -> server io
end