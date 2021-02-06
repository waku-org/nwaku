 # Tests of Swap contracts via external module
 #
import
  std/[unittest, options, tables, sets, osproc, strutils],
  ../test_helpers, ./utils

procSuite "Basic balance test":
  test "Get pwd":
    let (output, errC) = osproc.execCmdEx("pwd")
    echo output

    check:
      contains(output, "nim-waku")

#let cmdString = "npx hardhat balance --account 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
