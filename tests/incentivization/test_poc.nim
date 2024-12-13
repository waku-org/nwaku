{.used.}

import
  std/[options, strscans],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  web3

import
  waku/[node/peer_manager, waku_core],
  ../testlib/[assertions, wakucore, testasync, futures, testutils],
  waku/incentivization/[rpc, rpc_codec, common, txid_proof]

# All txids from Ethereum Sepolia testnet
const TxHashNonExisting* =
  TxHash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000000")
const TxHashContractCreation* =
  TxHash.fromHex("0xa2e39bee557144591fb7b2891ef44e1392f86c5ba1fc0afb6c0e862676ffd50f")
const TxHashContractCall* =
  TxHash.fromHex("0x2761f066eeae9a259a0247f529133dd01b7f57bf74254a64d897433397d321cb")
const TxHashSimpleTransfer* =
  TxHash.fromHex("0xa3985984b2ec3f1c3d473eb57a4820a56748f25dabbf9414f2b8380312b439cc")

const EthClient = "https://sepolia.infura.io/v3/470c2e9a16f24057aee6660081729fb9"

suite "Waku Incentivization PoC Eligibility Proofs":
  ## Tests for service incentivization PoC.
  ## In a client-server interaction, a client submits an eligibility proof to the server.
  ## The server provides the service if and only if the proof is valid.
  ## In PoC, a txid serves as eligibility proof.
  ## The txid reflects the confirmed payment from the client to the server.
  ## The request is eligible if the tx is confirmed and pays the correct amount to the correct address.
  ## The tx must also be of a "simple transfer" type (not a contract creation, not a contract call).
  ## See spec: https://github.com/waku-org/specs/blob/master/standards/core/incentivization.md

  asyncTest "incentivization PoC: non-existent tx is not eligible":
    ## Test that an unconfirmed tx is not eligible.
    let eligibilityProof =
      EligibilityProof(proofOfPayment: some(@(TxHashNonExisting.bytes())))
    let txIsEligible = await isEligible(eligibilityProof, EthClient)
    check:
      not txIsEligible

  asyncTest "incentivization PoC: contract creation tx is not eligible":
    ## Test that a contract creation tx is not eligible.
    let eligibilityProof =
      EligibilityProof(proofOfPayment: some(@(TxHashContractCreation.bytes())))
    let txIsEligible = await isEligible(eligibilityProof, EthClient)
    check:
      not txIsEligible

  asyncTest "incentivization PoC: contract call tx is not eligible":
    ## Test that a contract call tx is not eligible.
    ## This assumes a payment in native currency (ETH), not a token.
    let eligibilityProof =
      EligibilityProof(proofOfPayment: some(@(TxHashContractCall.bytes())))
    let txIsEligible = await isEligible(eligibilityProof, EthClient)
    check:
      not txIsEligible

  asyncTest "incentivization PoC: simple transfer tx is eligible":
    ## Test that a simple transfer tx is eligible (if necessary conditions hold).
    let eligibilityProof =
      EligibilityProof(proofOfPayment: some(@(TxHashSimpleTransfer.bytes())))
    let txIdExists = await isEligible(eligibilityProof, EthClient)
    check:
      txIdExists

  # TODO: add tests for simple transfer txs with wrong amount and wrong receiver
