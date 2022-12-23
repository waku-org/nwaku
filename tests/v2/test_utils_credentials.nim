{.used.}

import
  std/[options, os, strutils, sequtils],
  testutils/unittests, chronos, stint, json,
  stew/byteutils, 
  ../../waku/v2/utils/credentials,
  ../test_helpers,
  ./test_utils

procSuite "Credentials test suite":

  #[
  
  asyncTest "Create keystore":

    let filepath = "./testAppKeystore.txt"
    defer: removeFile(filepath)

    let keystore = createAppKeystore(path = filepath,
                        application = "test",
                        appIdentifier = "1234",
                        version = "0.1")

    check:
      keystore.isOk()
  ]#


  asyncTest "Load keystore":

    let filepath = "./testAppKeystore.txt"
    #defer: removeFile(filepath)

    let keystore = loadAppKeystore(path = filepath,
                                   application = "test",
                                   appIdentifier = "1234",
                                   version = "0.1")

    check:
      keystore.isOk()

    echo keystore.get()