{.used.}

import
  std/[options], testutils/unittests, chronos, web3, stew/byteutils, stint, strutils, os

import
  waku/[node/peer_manager, waku_core],
  ../testlib/[assertions],
  waku/incentivization/[rpc, rpc_codec, common, txid_proof],
  ../waku_rln_relay/[utils_onchain, utils]

const TxHashNonExisting =
  TxHash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000000")

# Constants for Anvil
const TxValueExpectedWei = 1000.u256
const EthClient = "ws://127.0.0.1:8540"

proc setupEligibilityTesting(
    eligibilityManager: EligibilityManager
): Future[(TxHash, TxHash, TxHash, TxHash, Address, Address)] {.async.} =
  ## Populate the local chain (connected to via eligibilityManager)
  ## with txs required for eligibility testing.
  ## 
  ## 1. Depoly a dummy contract that has a publicly callable function.
  ##    (While doing so, we confirm a contract creation tx.)
  ## 2. Confirm these transactions:
  ## - a contract call tx (eligibility test must fail)
  ## - a simple transfer with the wrong receiver (must fail)
  ## - a simple transfer with the wrong amount (must fail)
  ## - a simple transfer with the right receiver and amount (must pass)

  let web3 = eligibilityManager.web3

  let accounts = await web3.provider.eth_accounts()
  let sender = accounts[0]
  let receiverExpected = accounts[1]
  let receiverNotExpected = accounts[2]

  let txValueEthExpected = TxValueExpectedWei
  let txValueEthNotExpected = txValueEthExpected + 1

  # wrong receiver, wrong amount
  let txHashWrongReceiverRightAmount =
    await sendEthTransfer(web3, sender, receiverNotExpected, txValueEthExpected)

  # right receiver, wrong amount
  let txHashRightReceiverWrongAmount =
    await sendEthTransfer(web3, sender, receiverExpected, txValueEthNotExpected)

  # right receiver, right amount
  let txHashRightReceiverRightAmount =
    await sendEthTransfer(web3, sender, receiverExpected, txValueEthExpected)

  echo "TXHASHes:"
  echo $txHashWrongReceiverRightAmount
  echo $txHashRightReceiverWrongAmount
  echo $txHashRightReceiverRightAmount

  echo "SETTING UP CONTRACT"

  web3.defaultAccount = accounts[0]
  let ExampleStorageContract =
    "6080604052348015600e575f80fd5b506101438061001c5f395ff3fe608060405234801561000f575f80fd5b5060043610610034575f3560e01c80632e64cec1146100385780636057361d14610056575b5f80fd5b610040610072565b60405161004d919061009b565b60405180910390f35b610070600480360381019061006b91906100e2565b61007a565b005b5f8054905090565b805f8190555050565b5f819050919050565b61009581610083565b82525050565b5f6020820190506100ae5f83018461008c565b92915050565b5f80fd5b6100c181610083565b81146100cb575f80fd5b50565b5f813590506100dc816100b8565b92915050565b5f602082840312156100f7576100f66100b4565b5b5f610104848285016100ce565b9150509291505056fea26469706673582212209a0dd35336aff1eb3eeb11db76aa60a1427a12c1b92f945ea8c8d1dfa337cf2264736f6c634300081a0033"
  let receipt = await web3.deployContract(ExampleStorageContract)
  let txHashContractCreation = receipt.transactionHash

  echo $txHashContractCreation

  echo "SETUP COMPLETE"

  return (
    txHashWrongReceiverRightAmount, txHashRightReceiverWrongAmount,
    txHashRightReceiverRightAmount, txHashContractCreation, receiverExpected,
    receiverNotExpected,
  )

suite "Waku Incentivization PoC Eligibility Proofs":
  ## Tests for service incentivization PoC.
  ## In a client-server interaction, a client submits an eligibility proof to the server.
  ## The server provides the service if and only if the proof is valid.
  ## In PoC, a txid serves as eligibility proof.
  ## The txid reflects the confirmed payment from the client to the server.
  ## The request is eligible if the tx is confirmed and pays the correct amount to the correct address.
  ## The tx must also be of a "simple transfer" type (not a contract creation, not a contract call).
  ## See spec: https://github.com/waku-org/specs/blob/master/standards/core/incentivization.md

  ## Start Anvil
  let runAnvil {.used.} = runAnvil()

  var txHashWrongReceiverRightAmount: TxHash
  var txHashRightReceiverWrongAmount: TxHash
  var txHashRightReceiverRightAmount: TxHash
  var txHashContractCreation: TxHash

  var receiverExpected: Address
  var receiverNotExpected: Address

  asyncTest "incentivization PoC: non-existent tx is not eligible":
    ## Test that an unconfirmed tx is not eligible.

    let eligibilityManager = await EligibilityManager.init(EthClient)

    let (
      txHashWrongReceiverRightAmount, txHashRightReceiverWrongAmount,
      txHashRightReceiverRightAmount, txHashContractCreation, receiverExpected,
      receiverNotExpected,
    ) = await setupEligibilityTesting(eligibilityManager)

    let eligibilityProof =
      EligibilityProof(proofOfPayment: some(@(TxHashNonExisting.bytes())))
    let isEligible = await isEligibleTxId(
      eligibilityManager, eligibilityProof, receiverExpected, TxValueExpectedWei
    )
    check:
      isEligible.isErr()
    defer:
      await eligibilityManager.close()

  asyncTest "incentivization PoC: contract creation tx is not eligible":
    ## Test that a contract creation tx is not eligible.
    let eligibilityManager = await EligibilityManager.init(EthClient)

    let (
      txHashWrongReceiverRightAmount, txHashRightReceiverWrongAmount,
      txHashRightReceiverRightAmount, txHashContractCreation, receiverExpected,
      receiverNotExpected,
    ) = await setupEligibilityTesting(eligibilityManager)

    let eligibilityProof =
      EligibilityProof(proofOfPayment: some(@(txHashContractCreation.bytes())))
    let isEligible = await isEligibleTxId(
      eligibilityManager, eligibilityProof, receiverExpected, TxValueExpectedWei
    )
    check:
      isEligible.isErr()
    defer:
      await eligibilityManager.close()

  #[
  asyncTest "incentivization PoC: contract call tx is not eligible":
    ## Test that a contract call tx is not eligible.
    ## This assumes a payment in native currency (ETH), not a token.
    let eligibilityManager = await EligibilityManager.init(EthClientSepolia)
    let eligibilityProof =
      EligibilityProof(proofOfPayment: some(@(TxHashContractCall.bytes())))
    let isEligible = await isEligibleTxId(
      eligibilityManager, eligibilityProof, ExpectedToAddress, ExpectedValueSepolia
    )
    check:
      isEligible.isErr()
    defer:
      await eligibilityManager.close()
  ]#

  asyncTest "incentivization PoC: simple transfer tx is eligible":
    ## Test that a simple transfer tx is eligible (if necessary conditions hold).
    let eligibilityManager = await EligibilityManager.init(EthClient)

    let (
      txHashWrongReceiverRightAmount, txHashRightReceiverWrongAmount,
      txHashRightReceiverRightAmount, txHashContractCreation, receiverExpected,
      receiverNotExpected,
    ) = await setupEligibilityTesting(eligibilityManager)

    let eligibilityProof =
      EligibilityProof(proofOfPayment: some(@(txHashRightReceiverRightAmount.bytes())))
    let isEligible = await isEligibleTxId(
      eligibilityManager, eligibilityProof, receiverExpected, TxValueExpectedWei
    )
    assert isEligible.isOk(), isEligible.error
    defer:
      await eligibilityManager.close()

  # TODO: add tests for simple transfer txs with wrong amount and wrong receiver

  # Stop Anvil daemon
  stopAnvil(runAnvil)
