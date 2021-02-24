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
type NodeTaskJsonResult = Result[JsonNode, string]

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

proc execNodeTaskJson(taskStr: string): NodeTaskJsonResult =
  let cmdString = $cmdPrelude & $taskStr
  debug "execNodeTask", cmdString
  let (output, errC) = osproc.execCmdEx(cmdString)

  if errC>0:
    error "Error executing node task", output
    return err(output)

  debug "Command executed", output

  try:
    let json = parseJson(output)
    return ok(json)
  except JsonParsingError:
    return err("Unable to parse JSON:" & $output)


proc getBalance*(accountAddress: string): NodeTaskStrResult =
    let task = "balance --account " & $accountAddress
    let res = execNodeTaskJson(task)
    if res.isErr():
      return err("Unable to execute task" & $res)

    let json = res[]
    let balance = json["balance"].getStr()
    debug "getBalance", json=json, balance=balance
    return ok(balance)

proc setupSwap*(): JsonNode =
    let task = "setupSwap"
    let (output, errC) = execNodeTask(task)

    # XXX Assume succeeds
    let json = parseJson(output)
    return json
 
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

proc getERC20Balances*(erc20address: string): NodeTaskJsonResult =
    let task = "getBalances --erc20address '" & $erc20address & "'"
    let res = execNodeTaskJson(task)
    debug "getERC20Balances", res
    return res

proc redeemCheque*(swapAddress: string, signature: string): NodeTaskJsonResult =
  let task = "redeemCheque --swapaddress '" & $swapAddress & "' --signature '" & $signature & "'"
  let res = execNodeTaskJson(task)
  return res

when isMainModule:
  var aliceSwapAddress = "0x6C3d502f1a97d4470b881015b83D9Dd1062172e1"
  var sigRes = signCheque(aliceSwapAddress)
  if sigRes.isOk:
    echo "All good"
    echo "Signature ", sigRes[]
  else:
    echo sigRes
