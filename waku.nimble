mode = ScriptMode.Verbose

### Package
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "Waku, Private P2P Messaging for Resource-Rerestricted Devices"
license       = "MIT or Apache License 2.0"
srcDir        = "src"
#bin           = @["build/waku"]

### Dependencies
requires "nim >= 1.2.0",
  "chronicles",
  "confutils",
  "chronos",
  "eth",
  "json_rpc",
  "libbacktrace",
  "nimcrypto",
  "stew",
  "stint",
  "metrics",
  "libp2p" # For wakunode v2

### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(name: string, lang = "c") =
  buildBinary name, "tests/", "-d:chronicles_log_level=ERROR"
  exec "build/" & name

### Tasks
task test, "Run tests":
  test "all_tests"

task wakunode, "Build Waku cli":
  buildBinary "wakunode", "waku/node/v0/", "-d:chronicles_log_level=TRACE"

task wakusim, "Build Waku simulation tools":
  buildBinary "quicksim", "waku/node/v0/", "-d:chronicles_log_level=INFO"
  buildBinary "start_network", "waku/node/v0/", "-d:chronicles_log_level=DEBUG"

task wakunode2, "Build Experimental Waku cli":
  buildBinary "wakunode", "waku/node/v2/", "-d:chronicles_log_level=TRACE"

task wakusim2, "Build Experimental Waku simulation tools":
  buildBinary "quicksim", "waku/node/v2/", "-d:chronicles_log_level=INFO"
