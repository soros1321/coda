open Core
open Fold_lib
open Tuple_lib
open Coda_numbers
open Snark_params.Tick
open Import

type ('pk, 'amount, 'fee, 'nonce) t_ =
  {receiver: 'pk; amount: 'amount; fee: 'fee; nonce: 'nonce}
[@@deriving bin_io, eq, sexp, hash]

type t =
  ( Public_key.Compressed.t
  , Currency.Amount.t
  , Currency.Fee.t
  , Account_nonce.t )
  t_
[@@deriving bin_io, eq, sexp, hash]

val dummy : t

val gen : t Quickcheck.Generator.t

module Stable : sig
  module V1 : sig
    type nonrec ('pk, 'amount, 'fee, 'nonce) t_ =
                                                 ( 'pk
                                                 , 'amount
                                                 , 'fee
                                                 , 'nonce )
                                                 t_ =
      {receiver: 'pk; amount: 'amount; fee: 'fee; nonce: 'nonce}
    [@@deriving bin_io, eq, sexp, hash]

    type t =
      ( Public_key.Compressed.Stable.V1.t
      , Currency.Amount.Stable.V1.t
      , Currency.Fee.Stable.V1.t
      , Account_nonce.t )
      t_
    [@@deriving bin_io, eq, sexp, hash]
  end
end

type var =
  ( Public_key.Compressed.var
  , Currency.Amount.var
  , Currency.Fee.var
  , Account_nonce.Unpacked.var )
  t_

val length_in_triples : int

val typ : (var, t) Typ.t

val to_triples : t -> bool Triple.t list

val fold : t -> bool Triple.t Fold.t

val var_to_triples : var -> (Boolean.var Triple.t list, _) Checked.t

val var_of_t : t -> var
