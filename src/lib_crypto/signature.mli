(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2020 Metastate AG <hello@metastate.dev>                     *)
(* Copyright (c) 2022 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

(** Cryptographic signatures are versioned to expose different versions to
    different protocols, depending on the support.  *)

(** The type of conversion modules from one version to another. *)
module type CONV = sig
  module V_from : S.COMMON_SIGNATURE

  module V_to : S.COMMON_SIGNATURE

  val public_key_hash : V_from.Public_key_hash.t -> V_to.Public_key_hash.t

  val public_key : V_from.Public_key.t -> V_to.Public_key.t

  val secret_key : V_from.Secret_key.t -> V_to.Secret_key.t

  val signature : V_from.t -> V_to.t
end

(** The type of {e partial} conversion modules from one version to another. *)
module type CONV_OPT = sig
  module V_from : S.COMMON_SIGNATURE

  module V_to : S.COMMON_SIGNATURE

  val public_key_hash :
    V_from.Public_key_hash.t -> V_to.Public_key_hash.t option

  val public_key : V_from.Public_key.t -> V_to.Public_key.t option

  val secret_key : V_from.Secret_key.t -> V_to.Secret_key.t option

  val signature : V_from.t -> V_to.t option
end

(** The module [V_latest] is to be used by the shell and points to the latest
    available version of signatures. *)
module V_latest : module type of Signature_v1

(** [V0] supports Ed25519, Secp256k1, and P256. *)
module V0 : sig
  include module type of Signature_v0

  (** Converting from signatures of {!V_latest} to {!V0}. *)
  module Of_V_latest :
    CONV_OPT with module V_from := V_latest and module V_to := Signature_v0
end

(** [V1] supports Ed25519, Secp256k1, P256. It is a copy of {!V0} without type
    equalities. *)
module V1 : sig
  include module type of Signature_v1

  (** Converting from signatures of {!V_latest} to {!V1}. *)
  module Of_V_latest :
    CONV_OPT with module V_from := V_latest and module V_to := Signature_v1
end

include module type of V_latest

(** Converting from signatures of {!V_latest} to {!V_latest}. This module
    implements conversions which are the identity, so total, but we keep the
    signature as {!CONV_OPT} for compatibility with {!V0.Of_V_latest} and
    {!V1.Of_V_latest} and to ease snapshotting. *)
module Of_V_latest :
  CONV_OPT with module V_from := V_latest and module V_to := V_latest

(** Converting from signatures of {!V0} to {!V_latest}. *)
module Of_V0 : CONV with module V_from := V0 and module V_to := V_latest

(** Converting from signatures of {!V1} to {!V_latest}. *)
module Of_V1 : CONV with module V_from := V1 and module V_to := V_latest
