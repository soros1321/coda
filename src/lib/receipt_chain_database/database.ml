open Core_kernel

module Make
    (Transaction : Intf.Transaction)
    (Receipt_chain_hash : Intf.Receipt_chain_hash
                          with type transaction_payload := Transaction.payload)
    (Key_value_db : Key_value_database.S
                    with type key := Receipt_chain_hash.t
                     and type value :=
                                ( Receipt_chain_hash.t
                                , Transaction.t )
                                Tree_node.t) :
  Intf.Test.S
  with type receipt_chain_hash := Receipt_chain_hash.t
   and type transaction := Transaction.t
   and type database := Key_value_db.t = struct
  type t = Key_value_db.t

  let create ~directory = Key_value_db.create ~directory

  let prove t ~proving_receipt ~resulting_receipt =
    let open Or_error.Let_syntax in
    let rec parent_traversal start_receipt last_receipt :
        (Receipt_chain_hash.t * Transaction.t) list Or_error.t =
      match%bind
        Key_value_db.get t ~key:last_receipt
        |> Result.of_option
             ~error:
               (Error.createf
                  !"Cannot retrieve receipt: %{sexp: Receipt_chain_hash.t}"
                  last_receipt)
      with
      | Root ->
          Or_error.errorf
            !"The transaction of root hash %{sexp: Receipt_chain_hash.t} is \
              not recorded"
            last_receipt
      | Child {value; parent; _} ->
          if Receipt_chain_hash.equal start_receipt last_receipt then
            Or_error.return [(start_receipt, value)]
          else
            let%map subresult = parent_traversal start_receipt parent in
            (last_receipt, value) :: subresult
    in
    let%map result = parent_traversal proving_receipt resulting_receipt in
    List.rev result

  let get_transaction t ~receipt =
    Key_value_db.get t ~key:receipt
    |> Option.bind ~f:(function Root -> None | Child {value; _} -> Some value)

  let add t ~previous (transaction : Transaction.t) =
    let payload = Transaction.payload transaction in
    let receipt_chain_hash = Receipt_chain_hash.cons payload previous in
    let node, status =
      Option.value_map
        (Key_value_db.get t ~key:receipt_chain_hash)
        ~default:
          ( Some (Tree_node.Child {parent= previous; value= transaction})
          , `Ok receipt_chain_hash )
        ~f:(function
          | Root ->
              ( Some (Child {parent= previous; value= transaction})
              , `Duplicate receipt_chain_hash )
          | Child {parent= retrieved_parent; _} ->
              if not (Receipt_chain_hash.equal previous retrieved_parent) then
                (None, `Error_multiple_previous_receipts retrieved_parent)
              else
                ( Some (Child {parent= previous; value= transaction})
                , `Duplicate receipt_chain_hash ))
    in
    Option.iter node ~f:(function node ->
        Key_value_db.set t ~key:receipt_chain_hash ~data:node ) ;
    status

  let database t = t
end

let%test_module "receipt_database" =
  ( module struct
    module Transaction = struct
      include Char

      type payload = t [@@deriving bin_io]

      let payload = Fn.id
    end

    module Receipt_chain_hash = struct
      include String

      let empty = ""

      let cons (payload : Transaction.t) t = String.of_char payload ^ t
    end

    module Key_value_db =
      Key_value_database.Make_mock
        (Receipt_chain_hash)
        (struct
          type t = (Receipt_chain_hash.t, Transaction.t) Tree_node.t
          [@@deriving sexp]
        end)

    module Receipt_db = Make (Transaction) (Receipt_chain_hash) (Key_value_db)
    module Verifier = Verifier.Make (Transaction) (Receipt_chain_hash)

    let populate_random_path ~db transactions initial_receipt_hash =
      List.fold transactions ~init:[initial_receipt_hash]
        ~f:(fun current_leaves transaction ->
          let selected_forked_node = List.random_element_exn current_leaves in
          match
            Receipt_db.add db ~previous:selected_forked_node transaction
          with
          | `Ok checking_receipt -> checking_receipt :: current_leaves
          | `Duplicate _ -> current_leaves
          | `Error_multiple_previous_receipts _ ->
              failwith "We should not have multiple previous receipts" )
      |> ignore

    let%test_unit "Recording a sequence of transactions can generate a valid \
                   merkle list from the first transaction to the last \
                   transaction" =
      Quickcheck.test
        ~sexp_of:[%sexp_of: Receipt_chain_hash.t * Transaction.t list]
        Quickcheck.Generator.(
          tuple2 Receipt_chain_hash.gen (list_non_empty Transaction.gen))
        ~f:(fun (initial_receipt_chain, transactions) ->
          let db = Receipt_db.create ~directory:"" in
          let _, expected_merkle_path =
            List.fold_map transactions ~init:initial_receipt_chain
              ~f:(fun prev_receipt_chain transaction ->
                match
                  Receipt_db.add db ~previous:prev_receipt_chain transaction
                with
                | `Ok new_receipt_chain ->
                    (new_receipt_chain, (new_receipt_chain, transaction))
                | `Duplicate _ ->
                    failwith
                      "Each receipt chain in a sequence should be unique"
                | `Error_multiple_previous_receipts _ ->
                    failwith "We should not have multiple previous receipts" )
          in
          let (proving_receipt, _), (resulting_receipt, _) =
            ( List.hd_exn expected_merkle_path
            , List.last_exn expected_merkle_path )
          in
          [%test_result: (Receipt_chain_hash.t * Transaction.t) List.t]
            ~message:"Merkle paths should be equal"
            ~expect:expected_merkle_path
            ( Receipt_db.prove db ~proving_receipt ~resulting_receipt
            |> Or_error.ok_exn ) )

    let%test_unit "There exists a valid merkle list if a path exists in a \
                   tree of transactions" =
      Quickcheck.test
        ~sexp_of:
          [%sexp_of: Receipt_chain_hash.t * Transaction.t * Transaction.t list]
        Quickcheck.Generator.(
          tuple3 Receipt_chain_hash.gen Transaction.gen
            (list_non_empty Transaction.gen))
        ~f:(fun (prev_receipt_chain, initial_transaction, transactions) ->
          let db = Receipt_db.create ~directory:"" in
          let initial_receipt_chain =
            match
              Receipt_db.add db ~previous:prev_receipt_chain
                initial_transaction
            with
            | `Ok receipt_chain -> receipt_chain
            | `Duplicate _ ->
                failwith
                  "There should be no duplicate inserts since the first \
                   transaction is only being inserted"
            | `Error_multiple_previous_receipts _ ->
                failwith
                  "There should be no errors with previous receipts since the \
                   first transaction is only being inserted"
          in
          populate_random_path ~db transactions initial_receipt_chain ;
          let random_receipt_chain =
            List.filter
              (Hashtbl.keys (Receipt_db.database db))
              ~f:(Fn.compose not (String.equal prev_receipt_chain))
            |> List.random_element_exn
          in
          let merkle_list =
            Receipt_db.prove db ~proving_receipt:initial_receipt_chain
              ~resulting_receipt:random_receipt_chain
            |> Or_error.ok_exn
          in
          assert (
            Verifier.verify merkle_list ~resulting_receipt:random_receipt_chain
            |> Result.is_ok ) )

    let%test_unit "A merkle list should not exist if a proving receipt does \
                   not exist in the database" =
      Quickcheck.test
        ~sexp_of:
          [%sexp_of: Receipt_chain_hash.t * Transaction.t * Transaction.t list]
        Quickcheck.Generator.(
          tuple3 Receipt_chain_hash.gen Transaction.gen
            (list_non_empty Transaction.gen))
        ~f:
          (fun (initial_receipt_chain, unrecorded_transaction, transactions) ->
          let db = Receipt_db.create ~directory:"" in
          populate_random_path ~db transactions initial_receipt_chain ;
          let nonexisting_receipt_chain =
            let receipt_chains = Hashtbl.keys (Receipt_db.database db) in
            let largest_receipt_chain =
              List.max_elt receipt_chains ~compare:(fun chain1 chain2 ->
                  Int.compare (String.length chain1) (String.length chain2) )
              |> Option.value_exn
            in
            Receipt_chain_hash.cons unrecorded_transaction
              largest_receipt_chain
          in
          let random_receipt_chain =
            List.filter
              (Hashtbl.keys (Receipt_db.database db))
              ~f:(Fn.compose not (String.equal initial_receipt_chain))
            |> List.random_element_exn
          in
          assert (
            Receipt_db.prove db ~proving_receipt:nonexisting_receipt_chain
              ~resulting_receipt:random_receipt_chain
            |> Or_error.is_error ) )
  end )
