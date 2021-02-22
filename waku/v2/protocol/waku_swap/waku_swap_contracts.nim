# Code to interact with SWAP contracts module
#
import
  std/[osproc, strutils, json]

# TODO Signature
# XXX Assume node is running, etc
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
