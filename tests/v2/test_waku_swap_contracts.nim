 # Tests of Swap contracts via external module
 #
import
  std/[unittest, options, tables, sets, osproc, strutils, strformat, json],
  chronicles,
  ../test_helpers, ./utils,
  ../../waku/v2/protocol/waku_swap/waku_swap_contracts

procSuite "Basic balance test":
  var aliceSwapAddress = ""
  var signature = ""
  var erc20address = ""
  test "Get pwd of swap module":
    let (output, errC) = osproc.execCmdEx("(cd ../swap-contracts-module && pwd)")
    debug "output", output

    check:
      contains(output, "swap-contracts-module")

  test "Get balance from running node":
    # NOTE: This corresponds to the first default account in Hardhat
    let balance = waku_swap_contracts.getBalance("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

    check:
      contains(balance, "ETH")

  test "Setup Swap":
    let json = waku_swap_contracts.setupSwap()

    var aliceAddress = json["aliceAddress"].getStr()
    aliceSwapAddress = json["aliceSwapAddress"].getStr()
    erc20address = json["erc20address"].getStr()
    debug "erc20address", erc20address
    debug "json", json

    # Contains default Alice account
    check:
      contains(aliceAddress, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

  test "Sign Cheque":
    signature = waku_swap_contracts.signCheque(aliceSwapAddress)

    check:
      contains(signature, "0x")

  test "Get ERC20 Balances":
    let json = getERC20Balances(erc20address)

    check:
      json["bobBalance"].getInt() == 10000

  test "Redeem cheque and check balance":
    let json = waku_swap_contracts.redeemCheque(aliceSwapAddress, signature)
    var resp = json["resp"].getStr()
    debug "json", json

    debug "Get balances"
    let json2 = getERC20Balances(erc20address)
    debug "json", json2

    # Balance for Bob has now increased
    check:
      json2["bobBalance"].getInt() == 10500
