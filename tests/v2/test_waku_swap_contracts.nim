 # Tests of Swap contracts via external module
 #
import
  std/[unittest, options, tables, sets, osproc, strutils, strformat, json],
  ../test_helpers, ./utils

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
    let taskString = "npx hardhat --network localhost balance --account 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    let cmdString = "cd ../swap-contracts-module; " & &"{taskString}"
    echo cmdString
    let (output, errC) = osproc.execCmdEx(cmdString)
    echo output

    check:
      contains(output, "ETH")

  test "Setup Swap":
    let taskString = "npx hardhat --network localhost setupSwap"
    let cmdString = "cd ../swap-contracts-module; " & &"{taskString}"
    echo cmdString
    let (output, errC) = osproc.execCmdEx(cmdString)

    # XXX Assume succeeds
    let json = parseJson(output)
    var aliceAddress = json["aliceAddress"].getStr()
    aliceSwapAddress = json["aliceSwapAddress"].getStr()
    erc20address = json["erc20address"].getStr()
    echo erc20address
    echo json

    # Contains default Alice account
    check:
      contains(aliceAddress, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")

  test "Sign Cheque":
    #npx hardhat signCheque --swapaddress "0x94099942864EA81cCF197E9D71ac53310b1468D8"
    let taskString = "npx hardhat --network localhost signCheque --swapaddress '" & &"{aliceSwapAddress}" & "'"
    let cmdString = "cd ../swap-contracts-module; " & &"{taskString}"
    echo cmdString
    let (output, errC) = osproc.execCmdEx(cmdString)

    # XXX Assume succeeds
    let json = parseJson(output)
    signature = json["signature"].getStr()
    echo json
    echo signature

    # Contains some signature
    check:
      contains(signature, "0x")

  test "Get balances 1":
    let taskString = "npx hardhat --network localhost getBalances --erc20address '" & &"{erc20address}" & "'"
    let cmdString = "cd ../swap-contracts-module; " & &"{taskString}"
    echo cmdString
    let (output, errC) = osproc.execCmdEx(cmdString)

    # XXX Assume succeeds
    let json = parseJson(output)
    echo json

    # Contains some signature
    check:
      contains(signature, "0x")

  test "Redeem cheque and check balance":
    # XXX Simplify string creation
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
