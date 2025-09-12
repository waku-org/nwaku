# Package

version       = "0.1.0"
author        = "fryorcraken"
description   = "Test Waku with nimble"
license       = "MIT"
srcDir        = "src"
bin           = @["example"]


# Dependencies

requires "chronos"
requires "results"

proc ensureRln(libFile: string = "build/librln.a", version = "v0.7.0") =
  if not fileExists(libFile):
    echo "Building RLN library..."
    let buildDir = getCurrentDir()
    let outFile = libFile
    exec "bash ../scripts/build_rln.sh " & buildDir & " " & version & " " & outFile
  else:
    echo "RLN library already exists: " & libFile

before install:
  echo "ensure RLN before build"
  ensureRln()

#task build, "Build the project with RLN support":
#  additionalArguments = @["--passL:build/librln.a", "--passL:-lm"]

task run_example, "Run example":
  ensureRln()
  exec "nim c --passL:build/librln.a --passL:-lm -r src/waku_api_dogfood.nim"
