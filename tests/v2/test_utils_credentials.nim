{.used.}

import
  std/[options, os, strutils, sequtils],
  testutils/unittests, chronos, chronicles, stint, json,
  stew/byteutils, 
  ../../waku/v2/utils/credentials,
  ../test_helpers,
  ./test_utils

from  ../../waku/v2/protocol/waku_noise/noise_utils import randomSeqByte

procSuite "Credentials test suite":

  # We initialize the RNG in test_helpers
  let rng = rng()

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


  asyncTest "Add credential to keystore":

    let filepath = "./testAppKeystore.txt"
    #defer: removeFile(filepath)

    # We generate a random identity credential (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    var
      idTrapdoor = randomSeqByte(rng[], 32)
      idNullifier =  randomSeqByte(rng[], 32)
      idSecretHash = randomSeqByte(rng[], 32)
      idCommitment = randomSeqByte(rng[], 32)

    var idCredential = IdentityCredential(idTrapdoor: idTrapdoor, idNullifier: idNullifier, idSecretHash: idSecretHash, idCommitment: idCommitment)

    debug "the generated identity credential: ", idCredential

    var index = MembershipIndex(1)

    let rlnMembershipCredentials1 = MembershipCredentials(identityCredential: idCredential,
                                                         membershipGroups: @[MembershipGroup(chainId: "5",
                                                                                             contract: "0x0123456789012345678901234567890123456789",
                                                                                             treeIndex: index) ])

    # We generate a random identity credential (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    idTrapdoor = randomSeqByte(rng[], 32)
    idNullifier =  randomSeqByte(rng[], 32)
    idSecretHash = randomSeqByte(rng[], 32)
    idCommitment = randomSeqByte(rng[], 32)

    idCredential = IdentityCredential(idTrapdoor: idTrapdoor, idNullifier: idNullifier, idSecretHash: idSecretHash, idCommitment: idCommitment)

    debug "the generated identity credential: ", idCredential

    index = MembershipIndex(2)

    let rlnMembershipCredentials2 = MembershipCredentials(identityCredential: idCredential,
                                                         membershipGroups: @[MembershipGroup(chainId: "5",
                                                                                             contract: "0x0123456789012345678901234567890123456789",
                                                                                             treeIndex: index) ])

    let password = "%m0um0ucoW%"
    
    let keystore = addMembershipCredentials(path = filepath,
                                            credentials = @[rlnMembershipCredentials1, rlnMembershipCredentials2],
                                            password = password,
                                            application = "test",
                                            appIdentifier = "1234",
                                            version = "0.1")

    check:
      keystore.isOk()

  ]#

  asyncTest "Find credential in keystore":

    let filepath = "./testAppKeystore.txt"
    #defer: removeFile(filepath)

    # We generate a random identity credential (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    var
      idTrapdoor = randomSeqByte(rng[], 32)
      idNullifier =  randomSeqByte(rng[], 32)
      idSecretHash = randomSeqByte(rng[], 32)
      idCommitment = randomSeqByte(rng[], 32)

    var idCredential = IdentityCredential(idTrapdoor: idTrapdoor, idNullifier: idNullifier, idSecretHash: idSecretHash, idCommitment: idCommitment)

    debug "the generated identity credential: ", idCredential

    var index = MembershipIndex(1)

    # We generate two membership credentials with same identity credential
    let rlnMembershipCredentials1 = MembershipCredentials(identityCredential: idCredential,
                                                         membershipGroups: @[MembershipGroup(chainId: "5",
                                                                                             contract: "0x0123456789012345678901234567890123456789",
                                                                                             treeIndex: index) ])

    let rlnMembershipCredentials2 = MembershipCredentials(identityCredential: idCredential,
                                                         membershipGroups: @[MembershipGroup(chainId: "6",
                                                                                             contract: "0x0000000000000000000000000000000000000000",
                                                                                             treeIndex: index) ])

    # This is the same as rlnMembershipCredentials2, should not change the keystore entry of idCredential
    let rlnMembershipCredentials3 = MembershipCredentials(identityCredential: idCredential,
                                                         membershipGroups: @[MembershipGroup(chainId: "6",
                                                                                             contract: "0x0000000000000000000000000000000000000000",
                                                                                             treeIndex: index) ])

    let password = "%m0um0ucoW%"
    
    let keystore = addMembershipCredentials(path = filepath,
                                            credentials = @[rlnMembershipCredentials1, rlnMembershipCredentials2, rlnMembershipCredentials3],
                                            password = password,
                                            application = "test",
                                            appIdentifier = "1234",
                                            version = "0.1")

    check:
      keystore.isOk()