 # Tests of Swap contracts via external module
 #
import
  std/[unittest, options, tables, sets, osproc, strutils, strformat, json],
  ../test_helpers, ./utils,
  ../../waku/v2/protocol/waku_swap/waku_swap_contracts

procSuite "Basic balance test":
  var aliceSwapAddress = ""
  var signature = ""
  var erc20address = ""
  test "Get pwd of swap module":
    let (output, errC) = osproc.execCmdEx("(cd ../swap-contracts-module && pwd)")
    echo output

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
    echo erc20address
    echo json

    # Contains default Alice account
    check:
      contains(aliceAddress, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

  test "Sign Cheque":
    let signature = waku_swap_contracts.signCheque(aliceSwapAddress)

    check:
      contains(signature, "0x")

  test "Get ERC20 Balances":
    let json = getERC20Balances(erc20address)

    check:
      json["bobBalance"].getInt() == 10000

  test "Redeem cheque and check balance":
    let taskString = "npx hardhat --network localhost redeemCheque --swapaddress '" & &"{aliceSwapAddress}" & "' --signature '" & &"{signature}" & "'"
    let cmdString = "cd ../swap-contracts-module; " & &"{taskString}"
    echo cmdString
    let (output, errC) = osproc.execCmdEx(cmdString)

    # XXX Assume succeeds
    echo output
    let json = parseJson(output)
    var resp = json["resp"].getStr()
    echo json

    echo "Get balances"
    let taskString2 = "npx hardhat --network localhost getBalances --erc20address '" & &"{erc20address}" & "'"
    let cmdString2 = "cd ../swap-contracts-module; " & &"{taskString2}"
    echo cmdString2
    let (output2, errC2) = osproc.execCmdEx(cmdString2)

    # XXX Assume succeeds
    let json2 = parseJson(output2)
    echo json2

    # Balance for Bob has now increased
    check:
      json2["bobBalance"].getInt() == 10500
