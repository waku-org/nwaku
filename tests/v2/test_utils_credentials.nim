{.used.}

import
  std/[algorithm, options, os, strutils, sequtils, sets],
  testutils/unittests, chronos, chronicles, stint, json,
  stew/byteutils, 
  ../../waku/v2/utils/credentials,
  ../test_helpers,
  ./test_utils

from  ../../waku/v2/protocol/waku_noise/noise_utils import randomSeqByte

procSuite "Credentials test suite":

  # We initialize the RNG in test_helpers
  let rng = rng()

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
    defer: removeFile(filepath)

    let keystore = loadAppKeystore(path = filepath,
                                   application = "test",
                                   appIdentifier = "1234",
                                   version = "0.1")

    check:
      keystore.isOk()

  asyncTest "Add credential to keystore":

    let filepath = "./testAppKeystore.txt"
    defer: removeFile(filepath)

    # We generate a random identity credential (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    var
      idTrapdoor = randomSeqByte(rng[], 32)
      idNullifier =  randomSeqByte(rng[], 32)
      idSecretHash = randomSeqByte(rng[], 32)
      idCommitment = randomSeqByte(rng[], 32)

    var idCredential = IdentityCredential(idTrapdoor: idTrapdoor, idNullifier: idNullifier, idSecretHash: idSecretHash, idCommitment: idCommitment)

    debug "the generated identity credential: ", idCredential

    var contract = MembershipContract(chainId: "5", address: "0x0123456789012345678901234567890123456789")
    var index1 = MembershipIndex(1)
    var membershipGroup1 = MembershipGroup(membershipContract: contract, treeIndex: index1)


    let membershipCredentials1 = MembershipCredentials(identityCredential: idCredential,
                                                       membershipGroups: @[membershipGroup1])

    # We generate a random identity credential (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    idTrapdoor = randomSeqByte(rng[], 32)
    idNullifier =  randomSeqByte(rng[], 32)
    idSecretHash = randomSeqByte(rng[], 32)
    idCommitment = randomSeqByte(rng[], 32)

    idCredential = IdentityCredential(idTrapdoor: idTrapdoor, idNullifier: idNullifier, idSecretHash: idSecretHash, idCommitment: idCommitment)

    debug "the generated identity credential: ", idCredential

    var index2 = MembershipIndex(2)
    var membershipGroup2 = MembershipGroup(membershipContract: contract, treeIndex: index2)

    let membershipCredentials2 = MembershipCredentials(identityCredential: idCredential,
                                                       membershipGroups: @[membershipGroup2])

    let password = "%m0um0ucoW%"
    
    let keystore = addMembershipCredentials(path = filepath,
                                            credentials = @[membershipCredentials1, membershipCredentials2],
                                            password = password,
                                            application = "test",
                                            appIdentifier = "1234",
                                            version = "0.1")

    check:
      keystore.isOk()

  asyncTest "Add/retrieve credentials in keystore":

    let filepath = "./testAppKeystore.txt"
    defer: removeFile(filepath)

    # We generate two random identity credentials (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    var
      idTrapdoor1 = randomSeqByte(rng[], 32)
      idNullifier1 =  randomSeqByte(rng[], 32)
      idSecretHash1 = randomSeqByte(rng[], 32)
      idCommitment1 = randomSeqByte(rng[], 32)
      idCredential1 = IdentityCredential(idTrapdoor: idTrapdoor1, idNullifier: idNullifier1, idSecretHash: idSecretHash1, idCommitment: idCommitment1)
    
    var
      idTrapdoor2 = randomSeqByte(rng[], 32)
      idNullifier2 =  randomSeqByte(rng[], 32)
      idSecretHash2 = randomSeqByte(rng[], 32)
      idCommitment2 = randomSeqByte(rng[], 32)
      idCredential2 = IdentityCredential(idTrapdoor: idTrapdoor2, idNullifier: idNullifier2, idSecretHash: idSecretHash2, idCommitment: idCommitment2)
    
    # We generate two distinct membership groups
    var contract1 = MembershipContract(chainId: "5", address: "0x0123456789012345678901234567890123456789")
    var index1 = MembershipIndex(1)
    var membershipGroup1 = MembershipGroup(membershipContract: contract1, treeIndex: index1)

    var contract2 = MembershipContract(chainId: "6", address: "0x0000000000000000000000000000000000000000")
    var index2 = MembershipIndex(2)
    var membershipGroup2 = MembershipGroup(membershipContract: contract2, treeIndex: index2)

    # We generate three membership credentials
    let membershipCredentials1 = MembershipCredentials(identityCredential: idCredential1,
                                                       membershipGroups: @[membershipGroup1])

    let membershipCredentials2 = MembershipCredentials(identityCredential: idCredential2,
                                                       membershipGroups: @[membershipGroup2])

    let membershipCredentials3 = MembershipCredentials(identityCredential: idCredential1,
                                                       membershipGroups: @[membershipGroup2])

    # This is the same as rlnMembershipCredentials3, should not change the keystore entry of idCredential
    let membershipCredentials4 = MembershipCredentials(identityCredential: idCredential1,
                                                       membershipGroups: @[membershipGroup2])

    let password = "%m0um0ucoW%"
    
    # We add credentials to the keystore. Note that only 3 credentials should be effectively added, since rlnMembershipCredentials3 is equal to membershipCredentials2
    let keystore = addMembershipCredentials(path = filepath,
                                            credentials = @[membershipCredentials1, membershipCredentials2, membershipCredentials3, membershipCredentials4],
                                            password = password,
                                            application = "test",
                                            appIdentifier = "1234",
                                            version = "0.1")

    check:
      keystore.isOk()

    # We test retrieval of credentials.
    var expectedMembershipGroups1 = @[membershipGroup1, membershipGroup2]          
    expectedMembershipGroups1.sort(sortMembershipGroup)
    let expectedCredential1 = MembershipCredentials(identityCredential: idCredential1,
                                                    membershipGroups: expectedMembershipGroups1)


    var expectedMembershipGroups2 = @[membershipGroup2]          
    expectedMembershipGroups2.sort(sortMembershipGroup)
    let expectedCredential2 = MembershipCredentials(identityCredential: idCredential2,
                                                    membershipGroups: expectedMembershipGroups2)


    # We retrieve all credentials stored under password (no filter)
    var recoveredCredentials = getMembershipCredentials(path = filepath,
                                                        password = password,
                                                        application = "test",
                                                        appIdentifier = "1234",
                                                        version = "0.1")


    check:
      recoveredCredentials.isOk()
      recoveredCredentials.get() == @[expectedCredential1, expectedCredential2]


    # We retrieve credentials by filtering on an IdentityCredential
    recoveredCredentials = getMembershipCredentials(path = filepath,
                                                    password = password,
                                                    filterIdentityCredentials = @[idCredential1],
                                                    application = "test",
                                                    appIdentifier = "1234",
                                                    version = "0.1")

    check:
      recoveredCredentials.isOk()
      recoveredCredentials.get() == @[expectedCredential1]

    # We retrieve credentials by filtering on multiple IdentityCredentials
    recoveredCredentials = getMembershipCredentials(path = filepath,
                                                    password = password,
                                                    filterIdentityCredentials = @[idCredential1, idCredential2],
                                                    application = "test",
                                                    appIdentifier = "1234",
                                                    version = "0.1")

    check:  
      recoveredCredentials.isOk()
      recoveredCredentials.get() == @[expectedCredential1, expectedCredential2]

