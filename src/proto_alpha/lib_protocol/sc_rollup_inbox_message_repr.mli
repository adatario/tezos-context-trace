(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Trili Tech, <contact@trili.tech>                       *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

(** This module exposes a type {!t} that represents inbox messages. Inbox
    messages are produced by the Layer 1 protocol and are encoded using the
    {!to_bytes} function, before being added to a smart-contract rollup's inbox.

    They are part of the [Rollup Management Protocol] that defines the
    communication protocol for exchanging messages between Layer 1 and Layer 2
    for a smart-contract rollup.

    There are two types of inbox messages: external and internal.

     Internal messages originate from Layer 1 smart-contract and consist of:
     - [payload] the parameters passed to the smart-contract rollup.
     - [sender] the Layer 1 contract caller.
     - [source] the public key hash used for originating the transaction.

    External messages originate from the [Sc_rollup_add_messages]
    manager-operation and consists of strings. The Layer 2 node is responsible
    for decoding and interpreting these messages.
  *)

(** A type representing messages from Layer 1 to Layer 2. Internal ones are
    originated from Layer 1 smart-contracts and external ones are messages from
    an external manager operation. *)
type t =
  | Internal of {
      payload : Script_repr.expr;
          (** A Micheline value containing the parameters passed to the rollup. *)
      sender : Contract_repr.t;  (** The L1 caller contract. *)
      source : Signature.public_key_hash;
          (** The implicit account that originated the transaction. *)
    }
  | External of string

(** [bytes_of_inbox_message msg] encodes the inbox message [msg] in binary
    format. *)
val to_bytes : t -> string tzresult

module Internal_for_tests : sig
  (** [of_bytes bs] decodes [bs] as an [inbox_message]. *)
  val of_bytes : string -> t tzresult
end
