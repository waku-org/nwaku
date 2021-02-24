# Glue code to interact with SWAP contracts module.
#
# Assumes swap-contracts-module node is running.
#

#{.push raises: [Defect].}

import
  std/[osproc, strutils, json],
  chronicles, stew/results

logScope:
  topics = "wakuswapcontracts"

# TODO Richer error types than string, overkill for now...
type NodeTaskStrResult = Result[string, string]
type NodeTaskJSONResult = Result[JsonNode, string]

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

proc getBalance*(accountAddress: string): NodeTaskStrResult =
    let task = "balance --account " & $accountAddress
    let (output, errC) = execNodeTask(task)
    debug "getBalance", output

    if errC>0:
      error "Error executing node task", output
      return err(output)

    try:
      let json = parseJson(output)
      let balance = json["balance"].getStr()
      debug "getBalance", json=json, balance=balance
      return ok(balance)
    except JsonParsingError:
      return err("Unable to parse JSON:" & $output)

proc setupSwap*(): JsonNode =
    let task = "setupSwap"
    let (output, errC) = execNodeTask(task)

    # XXX Assume succeeds
    let json = parseJson(output)
    return json
 
# TODO JSON
proc signCheque*(swapAddress: string): NodeTaskStrResult =
  let task = "signCheque --swapaddress '" & $swapAddress & "'"
  var (output, errC) = execNodeTask(task)

  if errC>0:
    error "Error executing node task", output
    return err(output)

  debug "Command executed", output

  try:
    let json = parseJson(output)
    let signature = json["signature"].getStr()
    info "signCheque", json=json, signature=signature
    return ok(signature)
  except JsonParsingError:
    return err("Unable to parse JSON:" & $output)

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


var aliceSwapAddress = "0x6C3d502f1a97d4470b881015b83D9Dd1062172e1"
var sigRes = signCheque(aliceSwapAddress)
if sigRes.isOk:
  echo "All good"
  echo "Signature ", sigRes[]
else:
  echo sigRes
