 # Tests of Swap contracts via external module
 #
import
  std/[unittest, options, tables, sets, osproc, strutils, strformat],
  ../test_helpers, ./utils

procSuite "Basic balance test":
  test "Get pwd of swap module":
    let (output, errC) = osproc.execCmdEx("(cd ../swap-contracts-module && pwd)")
    echo output

    check:
      contains(output, "swap-contracts-module")

  test "Get balance from running node":
    # NOTE: This corresponds to the first default account in Hardhat
    let taskString = "npx hardhat balance --account 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    let cmdString = "cd ../swap-contracts-module; " & &"{taskString}"
    echo cmdString
    let (output, errC) = osproc.execCmdEx(cmdString)
    echo output

    check:
      contains(output, "ETH")

  # TODO Setup more tasks in Swap module for e2e PoC
  # TODO Use basic JSON interface instead of strings for basic IO
