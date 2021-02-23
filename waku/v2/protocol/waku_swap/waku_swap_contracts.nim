# Glue code to interact with SWAP contracts module.
#
# Assumes swap-contracts-module node is running.
#
import
  std/[osproc, strutils, json],
  chronicles

logScope:
  topics = "wakuswapcontracts"

# XXX In general this is not a good API, more a collection of hacky glue code for PoC.
#
# TODO Error handling

# Interacts with node in sibling path and interacts with a local Hardhat node.
const taskPrelude = "npx hardhat --network localhost "
const cmdPrelude = "cd ../swap-contracts-module; " & taskPrelude

proc execNodeTask(taskStr: string): tuple[output: TaintedString, exitCode: int] =
  let cmdString = $cmdPrelude & $taskStr
  debug "execNodeTask", cmdString
  return osproc.execCmdEx(cmdString)

# TODO JSON?
proc getBalance*(accountAddress: string): string =
    let task = "balance --account " & $accountAddress
    let (output, errC) = execNodeTask(task)
    debug "getBalance", output
    return output

proc setupSwap*(): JsonNode =
    let task = "setupSwap"
    let (output, errC) = execNodeTask(task)

    # XXX Assume succeeds
    let json = parseJson(output)
    return json
 
# TODO Signature
proc signCheque*(swapAddress: string): string =
  let task = "signCheque --swapaddress '" & $swapAddress & "'"
  let (output, errC) = execNodeTask(task)

 # XXX Assume succeeds
  let json = parseJson(output)
  let signature = json["signature"].getStr()
  debug "signCheque", json=json, signature=signature
  return signature

proc getERC20Balances*(erc20address: string): JsonNode =
    let task = "getBalances --erc20address '" & $erc20address & "'"
    let (output, errC) = execNodeTask(task)

    # XXX Assume succeeds
    let json = parseJson(output)
    return json

proc redeemCheque*(swapAddress: string, signature: string): JsonNode =
  let task = "redeemCheque --swapaddress '" & $swapAddress & "' --signature '" & $signature & "'"
  let (output, errC) = execNodeTask(task)

  # XXX Assume succeeds
  let json = parseJson(output)
  return json
