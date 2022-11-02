mode = ScriptMode.Verbose

### Package
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "Waku, Private P2P Messaging for Resource-Restricted Devices"
license       = "MIT or Apache License 2.0"
#bin           = @["build/waku"]

### Dependencies
requires "nim >= 1.6.0",
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
  "libp2p", # Only for Waku v2
  "web3",
  "presto",
  "regex"

### Helper functions
proc buildBinary(name: string, srcDir = "./", params = "", lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2..<paramCount():
    extra_params &= " " & paramStr(i)
  exec "nim " & lang & " --out:build/" & name & " " & extra_params & " " & srcDir & name & ".nim"

proc test(name: string, params = "-d:chronicles_log_level=DEBUG", lang = "c") =
  # XXX: When running `> NIM_PARAMS="-d:chronicles_log_level=INFO" make test2`
  # I expect compiler flag to be overridden, however it stays with whatever is
  # specified here.
  buildBinary name, "tests/", params
  exec "build/" & name

### Whisper tasks
task testwhisper, "Build & run Whisper tests":
  test "all_tests_whisper", "-d:chronicles_log_level=WARN -d:chronosStrictException"

### Waku v1 tasks
task wakunode1, "Build Waku v1 cli node":
  buildBinary "wakunode1", "waku/v1/node/",
    "-d:chronicles_log_level=DEBUG -d:chronosStrictException"

task sim1, "Build Waku v1 simulation tools":
  buildBinary "quicksim", "waku/v1/node/",
    "-d:chronicles_log_level=INFO -d:chronosStrictException"
  buildBinary "start_network", "waku/v1/node/",
    "-d:chronicles_log_level=DEBUG -d:chronosStrictException"

task example1, "Build Waku v1 example":
  buildBinary "example", "examples/v1/",
    "-d:chronicles_log_level=DEBUG -d:chronosStrictException"

task test1, "Build & run Waku v1 tests":
  test "all_tests_v1", "-d:chronicles_log_level=WARN -d:chronosStrictException"

### Waku v2 tasks
task wakunode2, "Build Waku v2 (experimental) cli node":
  let name = "wakunode2"
  buildBinary name, "apps/wakunode2/", "-d:chronicles_log_level=TRACE"

task bridge, "Build Waku v1 - v2 bridge":
  let name = "wakubridge"
  buildBinary name, "apps/wakubridge/", "-d:chronicles_log_level=TRACE"

task test2, "Build & run Waku v2 tests":
  test "all_tests_v2"


task sim2, "Build Waku v2 simulation tools":
  buildBinary "quicksim2", "tools/simulation/", "-d:chronicles_log_level=DEBUG"
  buildBinary "start_network2", "tools/simulation/", "-d:chronicles_log_level=TRACE"

task example2, "Build Waku v2 example":
  let name = "basic2"
  buildBinary name, "examples/v2/", "-d:chronicles_log_level=DEBUG"

task scripts2, "Build Waku v2 scripts":
  buildBinary "rpc_publish", "tools/scripts/", "-d:chronicles_log_level=DEBUG"
  buildBinary "rpc_subscribe", "tools/scripts/", "-d:chronicles_log_level=DEBUG"
  buildBinary "rpc_subscribe_filter", "tools/scripts/", "-d:chronicles_log_level=DEBUG"
  buildBinary "rpc_query", "tools/scripts/", "-d:chronicles_log_level=DEBUG"
  buildBinary "rpc_info", "tools/scripts/", "-d:chronicles_log_level=DEBUG"

task chat2, "Build example Waku v2 chat usage":
  # NOTE For debugging, set debug level. For chat usage we want minimal log
  # output to STDOUT. Can be fixed by redirecting logs to file (e.g.)
  #buildBinary name, "examples/v2/", "-d:chronicles_log_level=WARN"

  let name = "chat2"
  buildBinary name, "apps/chat2/", "-d:chronicles_log_level=TRACE -d:chronicles_sinks=textlines[file] -d:ssl"

task chat2bridge, "Build chat2bridge":
  let name = "chat2bridge"
  buildBinary name, "apps/chat2bridge/", "-d:chronicles_log_level=TRACE"


### Waku Tooling
task wakucanary, "Build waku-canary tool":
  let name = "wakucanary"
  buildBinary name, "tools/wakucanary/", "-d:chronicles_log_level=TRACE"
