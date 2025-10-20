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
requires "waku#da5767a388f1a4ab0b7ce43f3765d20cf1d098ed"

import os

proc ensureRln(libFile: string = "build/librln.a", version = "v0.8.0") =
  if not fileExists(libFile):
    echo "Building RLN library..."
    let buildDir = parentDir(parentDir(getCurrentDir())) & "/vendor/zerokit"
    let outFile = libFile
    exec "bash ../../scripts/build_rln.sh " & buildDir & " " & version & " " & outFile
  else:
    echo "RLN library already exists: " & libFile

before build:
    ensureRln()