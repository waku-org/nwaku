mode = ScriptMode.Verbose

### Package
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "Waku, Private P2P Messaging for Resource-Restricted Devices"
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
task test, "Run waku v1 tests":
  test "all_tests"

task test2, "Run waku v2 tests":
  test "all_tests_v2"

task wakunode, "Build Waku cli":
  buildBinary "wakunode", "waku/node/v1/", "-d:chronicles_log_level=TRACE"

task wakusim, "Build Waku simulation tools":
  buildBinary "quicksim", "waku/node/v1/", "-d:chronicles_log_level=INFO"
  buildBinary "start_network", "waku/node/v1/", "-d:chronicles_log_level=DEBUG"

task protocol2, "Build the experimental Waku protocol":
  buildBinary "waku_protocol2", "waku/protocol/v2/", "-d:chronicles_log_level=TRACE"

task wakunode2, "Build Experimental Waku cli":
  buildBinary "wakunode2", "waku/node/v2/", "-d:chronicles_log_level=TRACE"

task wakusim2, "Build Experimental Waku simulation tools":
  buildBinary "quicksim2", "waku/node/v2/", "-d:chronicles_log_level=DEBUG"
  buildBinary "start_network2", "waku/node/v2/", "-d:chronicles_log_level=TRACE"

task wakuexample2, "Build example Waku usage":
  let name = "basic2"
  buildBinary name, "examples/v2/", "-d:chronicles_log_level=DEBUG"
  exec "build/" & name
