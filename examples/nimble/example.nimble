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
requires "waku"

proc ensureRln(libFile: string = "build/librln.a", version = "v0.7.0") =
  if not fileExists(libFile):
    echo "Building RLN library..."
    let buildDir = getCurrentDir()
    let outFile = libFile
    exec "bash ../../scripts/build_rln.sh " & buildDir & " " & version & " " & outFile
  else:
    echo "RLN library already exists: " & libFile

before build:
  echo "Ensure RLN before build"
  ensureRln()

before install:
  echo "Ensure RLN before install"
  ensureRln()
