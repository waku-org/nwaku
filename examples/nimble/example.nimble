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
requires "waku#f380604fb1fa9202cee8d1d0068d078b9a90aaad" # pinning to when nim-libp2p release is fine