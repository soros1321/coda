open Core

type payment = Payment.With_valid_signature.t [@@deriving bin_io, sexp]

type fee_transfer = Fee_transfer.t [@@deriving bin_io, sexp]

type t =
  | Payment of payment
  | Fee_transfer of Fee_transfer.t
  | Coinbase of Coinbase.t
[@@deriving bin_io, sexp]

let fee_excess = function
  | Payment t ->
      Ok (Currency.Fee.Signed.of_unsigned (t :> Payment.t).payload.fee)
  | Fee_transfer t -> Fee_transfer.fee_excess t
  | Coinbase t -> Coinbase.fee_excess t

let supply_increase = function
  | Payment _ | Fee_transfer _ -> Ok Currency.Amount.zero
  | Coinbase t -> Coinbase.supply_increase t
