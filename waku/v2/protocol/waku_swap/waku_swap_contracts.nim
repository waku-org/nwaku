# Glue code to interact with SWAP contracts module.
#
# Assumes swap-contracts-module node is running.
#
import
  std/[osproc, strutils, json]

# XXX In general this is not a good API, more a collection of hacky glue code for PoC.
#
# TODO Error handling
# TODO util for task/cmd string

# TODO JSON?
proc getBalance*(accountAddress: string): string =
    # NOTE: This corresponds to the first default account in Hardhat
    let taskString = "npx hardhat --network localhost balance --account " & $accountAddress
    let cmdString = "cd ../swap-contracts-module; " & $taskString
    echo cmdString
    let (output, errC) = osproc.execCmdEx(cmdString)
    echo output
    return output

proc setupSwap*(): JsonNode =
    let taskString = "npx hardhat --network localhost setupSwap"
    let cmdString = "cd ../swap-contracts-module; " & $taskString
    echo cmdString
    let (output, errC) = osproc.execCmdEx(cmdString)

    # XXX Assume succeeds
    let json = parseJson(output)
    return json
 
# TODO Signature
proc signCheque*(swapAddress: string): string =
  let taskString = "npx hardhat --network localhost signCheque --swapaddress '" & $swapAddress & "'"
  let cmdString = "cd ../swap-contracts-module; " & $taskString
  echo cmdString
  let (output, errC) = osproc.execCmdEx(cmdString)

 # XXX Assume succeeds
  let json = parseJson(output)
  let signature = json["signature"].getStr()
  echo json
  echo signature
  return signature

proc getERC20Balances*(erc20address: string): JsonNode =
    let taskString = "npx hardhat --network localhost getBalances --erc20address '" & $erc20address & "'"
    let cmdString = "cd ../swap-contracts-module; " & $taskString
    echo cmdString
    let (output, errC) = osproc.execCmdEx(cmdString)

    # XXX Assume succeeds
    let json = parseJson(output)
    return json
