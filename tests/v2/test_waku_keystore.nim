{.used.}

import
  std/[algorithm, json, options, os],
  testutils/unittests, chronos, stint
import
  ../../waku/v2/waku_keystore,
  ./testlib/common

from  ../../waku/v2/waku_noise/noise_utils import randomSeqByte

procSuite "Credentials test suite":

  let testAppInfo = AppInfo(application: "test", appIdentifier: "1234", version: "0.1")

  test "Create keystore":

    let filepath = "./testAppKeystore.txt"
    defer: removeFile(filepath)

    let keystoreRes = createAppKeystore(path = filepath,
                                        appInfo = testAppInfo)

    check:
      keystoreRes.isOk()

  test "Load keystore":

    let filepath = "./testAppKeystore.txt"
    defer: removeFile(filepath)

    # If no keystore exists at filepath, a new one is created for appInfo and empty credentials
    let keystoreRes = loadAppKeystore(path = filepath,
                                      appInfo = testAppInfo)

    check:
      keystoreRes.isOk()

    let keystore = keystoreRes.get()

    check:
      keystore.hasKeys(["application", "appIdentifier", "version", "credentials"])
      keystore["application"].getStr() == testAppInfo.application
      keystore["appIdentifier"].getStr() == testAppInfo.appIdentifier
      keystore["version"].getStr() == testAppInfo.version
      # We assume the loaded keystore to not have credentials set (previous tests delete the keystore at filepath)
      keystore["credentials"].getElems().len() == 0

  test "Add credentials to keystore":

    let filepath = "./testAppKeystore.txt"
    defer: removeFile(filepath)

    # We generate a random identity credential (inter-value constrains are not enforced, otherwise we need to load e.g. zerokit RLN keygen)
    var
      idTrapdoor = randomSeqByte(rng[], 32)
      idNullifier =  randomSeqByte(rng[], 32)
      idSecretHash = randomSeqByte(rng[], 32)
      idCommitment = randomSeqByte(rng[], 32)

    var idCredential = IdentityCredential(idTrapdoor: idTrapdoor, idNullifier: idNullifier, idSecretHash: idSecretHash, idCommitment: idCommitment)

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

    var index2 = MembershipIndex(2)
    var membershipGroup2 = MembershipGroup(membershipContract: contract, treeIndex: index2)

    let membershipCredentials2 = MembershipCredentials(identityCredential: idCredential,
                                                       membershipGroups: @[membershipGroup2])

    let password = "%m0um0ucoW%"

    let keystoreRes = addMembershipCredentials(path = filepath,
                                               credentials = @[membershipCredentials1, membershipCredentials2],
                                               password = password,
                                               appInfo = testAppInfo)

    check:
      keystoreRes.isOk()

  test "Add/retrieve credentials in keystore":

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
    let keystoreRes = addMembershipCredentials(path = filepath,
                                               credentials = @[membershipCredentials1, membershipCredentials2, membershipCredentials3, membershipCredentials4],
                                               password = password,
                                               appInfo = testAppInfo)

    check:
      keystoreRes.isOk()

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
    var recoveredCredentialsRes = getMembershipCredentials(path = filepath,
                                                           password = password,
                                                           appInfo = testAppInfo)

    check:
      recoveredCredentialsRes.isOk()
      recoveredCredentialsRes.get() == @[expectedCredential1, expectedCredential2]


    # We retrieve credentials by filtering on an IdentityCredential
    recoveredCredentialsRes = getMembershipCredentials(path = filepath,
                                                       password = password,
                                                       filterIdentityCredentials = @[idCredential1],
                                                       appInfo = testAppInfo)

    check:
      recoveredCredentialsRes.isOk()
      recoveredCredentialsRes.get() == @[expectedCredential1]

    # We retrieve credentials by filtering on multiple IdentityCredentials
    recoveredCredentialsRes = getMembershipCredentials(path = filepath,
                                                       password = password,
                                                       filterIdentityCredentials = @[idCredential1, idCredential2],
                                                       appInfo = testAppInfo)

    check:
      recoveredCredentialsRes.isOk()
      recoveredCredentialsRes.get() == @[expectedCredential1, expectedCredential2]

