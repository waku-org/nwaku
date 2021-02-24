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
    let balRes = waku_swap_contracts.getBalance("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
    var balance: float
    if balRes.isOk():
      let json = balRes[]
      let balanceStr = json["balance"].getStr()
      balance = parseFloat(balanceStr)

    check:
      balRes.isOk()
      balance > 0

  test "Setup Swap":
    let res = waku_swap_contracts.setupSwap()
    let json = res[]

    var aliceAddress = json["aliceAddress"].getStr()
    aliceSwapAddress = json["aliceSwapAddress"].getStr()
    erc20address = json["erc20address"].getStr()
    debug "erc20address", erc20address
    debug "json", json

    # Contains default Alice account
    check:
      contains(aliceAddress, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

  test "Sign Cheque":
    var sigRes = waku_swap_contracts.signCheque(aliceSwapAddress)
    if sigRes.isOk():
      let json = sigRes[]
      signature = json["signature"].getStr()

    check:
      sigRes.isOk()
      contains(signature, "0x")

  test "Get ERC20 Balances":
    let res = waku_swap_contracts.getERC20Balances(erc20address)

    check:
      res.isOk()
      res[]["bobBalance"].getInt() == 10000

  test "Redeem cheque and check balance":
    let redeemRes = waku_swap_contracts.redeemCheque(aliceSwapAddress, signature)
    var resp = redeemRes[]["resp"].getStr()
    debug "Redeem resp", resp

    let balRes = getERC20Balances(erc20address)

    # Balance for Bob has now increased
    check:
      redeemRes.isOk()
      balRes.isOk()
      balRes[]["bobBalance"].getInt() == 10500
