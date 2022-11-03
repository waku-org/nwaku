# Glue code to interact with SWAP contracts module.
#
# Assumes swap-contracts-module node is running.
#

{.push raises: [Defect].}

import
  std/[osproc, strutils, json],
  chronicles, stew/results

logScope:
  topics = "waku swap"

# TODO Richer error types than string, overkill for now...
type NodeTaskJsonResult = Result[JsonNode, string]

# XXX In general this is not a great API, more a collection of hacky glue code for PoC.

# Interacts with node in sibling path and interacts with a local Hardhat node.
const taskPrelude = "npx hardhat --network localhost "
const cmdPrelude = "cd ../swap-contracts-module; " & taskPrelude

# proc execNodeTask(taskStr: string): tuple[output: string, exitCode: int] =
#   let cmdString = $cmdPrelude & $taskStr
#   debug "execNodeTask", cmdString
#   return osproc.execCmdEx(cmdString)

proc execNodeTaskJson(taskStr: string): NodeTaskJsonResult =
  let cmdString = $cmdPrelude & $taskStr
  debug "execNodeTask", cmdString

  try:
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
    except Exception:
      return err("Unable to parse JSON:" & $output)

  except OSError:
    return err("Unable to execute command, OSError:" & $taskStr)
  except Exception:
    return err("Unable to execute command:" & $taskStr)

proc getBalance*(accountAddress: string): NodeTaskJsonResult =
    let task = "balance --account " & $accountAddress
    let res = execNodeTaskJson(task)
    return res

proc setupSwap*(): NodeTaskJsonResult =
    let task = "setupSwap"
    let res = execNodeTaskJson(task)
    return res
 
proc signCheque*(swapAddress: string): NodeTaskJsonResult =
  let task = "signCheque --swapaddress '" & $swapAddress & "'"
  var res = execNodeTaskJson(task)
  return res

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
  if sigRes.isOk():
    echo "All good"
    echo "Signature ", sigRes[]
  else:
    echo sigRes
