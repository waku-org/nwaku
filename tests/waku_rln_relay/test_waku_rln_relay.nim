{.used.}

import
  std/[options, os, sequtils, times, tempfiles],
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  libp2p/crypto/crypto
import
  waku/[
    waku_core,
    waku_rln_relay,
    waku_rln_relay/rln,
    waku_rln_relay/protocol_metrics,
    waku_keystore,
  ],
  ../testlib/common,
  ./rln/waku_rln_relay_utils

suite "Waku rln relay":
  test "key_gen Nim Wrappers":
    let merkleDepth: csize_t = 20

    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()

    # keysBufferPtr will hold the generated identity credential i.e., id trapdoor, nullifier, secret hash and commitment
    var keysBuffer: Buffer
    let
      keysBufferPtr = addr(keysBuffer)
      done = key_gen(rlnInstance.get(), keysBufferPtr)
    require:
      # check whether the keys are generated successfully
      done

    let generatedKeys = cast[ptr array[4 * 32, byte]](keysBufferPtr.`ptr`)[]
    check:
      # the id trapdoor, nullifier, secert hash and commitment together are 4*32 bytes
      generatedKeys.len == 4 * 32
    debug "generated keys: ", generatedKeys

  test "membership Key Generation":
    # create an RLN instance
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()

    let idCredentialsRes = membershipKeyGen(rlnInstance.get())
    require:
      idCredentialsRes.isOk()

    let idCredential = idCredentialsRes.get()
    let empty = default(array[32, byte])
    check:
      idCredential.idTrapdoor.len == 32
      idCredential.idNullifier.len == 32
      idCredential.idSecretHash.len == 32
      idCredential.idCommitment.len == 32
      idCredential.idTrapdoor != empty
      idCredential.idNullifier != empty
      idCredential.idSecretHash != empty
      idCredential.idCommitment != empty

    debug "the generated identity credential: ", idCredential

  test "getRoot Nim binding":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()

    # read the Merkle Tree root
    let
      root1 {.noinit.}: Buffer = Buffer()
      rootPtr1 = unsafeAddr(root1)
      getRootSuccessful1 = getRoot(rlnInstance.get(), rootPtr1)
    require:
      getRootSuccessful1
      root1.len == 32

    # read the Merkle Tree root
    let
      root2 {.noinit.}: Buffer = Buffer()
      rootPtr2 = unsafeAddr(root2)
      getRootSuccessful2 = getRoot(rlnInstance.get(), rootPtr2)
    require:
      getRootSuccessful2
      root2.len == 32

    let rootValue1 = cast[ptr array[32, byte]](root1.`ptr`)
    let rootHex1 = rootValue1[].inHex

    let rootValue2 = cast[ptr array[32, byte]](root2.`ptr`)
    let rootHex2 = rootValue2[].inHex

    # the two roots must be identical
    check:
      rootHex1 == rootHex2
  test "getMerkleRoot utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    # read the Merkle Tree root
    let root1 = getMerkleRoot(rln)
    require:
      root1.isOk()
    let rootHex1 = root1.value().inHex

    # read the Merkle Tree root
    let root2 = getMerkleRoot(rln)
    require:
      root2.isOk()
    let rootHex2 = root2.value().inHex

    # the two roots must be identical
    check:
      rootHex1 == rootHex2

  test "update_next_member Nim Wrapper":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()
    # generate an identity credential
    let idCredentialRes = membershipKeyGen(rln)
    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()
    let pkBuffer = toBuffer(idCredential.idCommitment)
    let pkBufferPtr = unsafeAddr(pkBuffer)

    # add the member to the tree
    let memberAdded = updateNextMember(rln, pkBufferPtr)
    check:
      memberAdded

  test "getMember Nim wrapper":
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()
    # generate an identity credential
    let idCredentialRes = membershipKeyGen(rln)
    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()
    let pkBuffer = toBuffer(idCredential.idCommitment)
    let pkBufferPtr = unsafeAddr(pkBuffer)

    let
      root1 {.noinit.}: Buffer = Buffer()
      rootPtr1 = unsafeAddr(root1)
      getRootSuccessful1 = getRoot(rlnInstance.get(), rootPtr1)

    # add the member to the tree
    let memberAdded = updateNextMember(rln, pkBufferPtr)
    require:
      memberAdded

    let leafRes = getMember(rln, 0)
    require:
      leafRes.isOk()
    let leaf = leafRes.get()
    let leafHex = leaf.inHex()
    check:
      leafHex == idCredential.idCommitment.inHex()

  test "delete_member Nim wrapper":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    # generate an identity credential
    let rln = rlnInstance.get()
    let idCredentialRes = rln.membershipKeyGen()
    require:
      idCredentialRes.isOk()
      rln.insertMember(idCredentialRes.get().idCommitment)

    # delete the first member
    let deletedMemberIndex = MembershipIndex(0)
    let deletionSuccess = rln.deleteMember(deletedMemberIndex)
    check:
      deletionSuccess

  test "insertMembers rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()
    # generate an identity credential
    let idCredentialRes = rln.membershipKeyGen()
    require:
      idCredentialRes.isOk()
    check:
      rln.insertMembers(0, @[idCredentialRes.get().idCommitment])
      rln.leavesSet() == 1

  test "insertMember rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()
    # generate an identity credential
    let idCredentialRes = rln.membershipKeyGen()
    require:
      idCredentialRes.isOk()
    check:
      rln.insertMember(idCredentialRes.get().idCommitment)

  test "removeMember rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let idCredentialRes = rln.membershipKeyGen()
    require:
      idCredentialRes.isOk()
      rln.insertMember(idCredentialRes.get().idCommitment)
    check:
      rln.removeMember(MembershipIndex(0))

  test "setMetadata rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()
    check:
      rln
      .setMetadata(
        RlnMetadata(
          lastProcessedBlock: 128,
          chainId: 1155511,
          contractAddress: "0x9c09146844c1326c2dbc41c451766c7138f88155",
        )
      )
      .isOk()

  test "getMetadata rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    require:
      rln
      .setMetadata(
        RlnMetadata(
          lastProcessedBlock: 128,
          chainId: 1155511,
          contractAddress: "0x9c09146844c1326c2dbc41c451766c7138f88155",
        )
      )
      .isOk()

    let metadataOpt = rln.getMetadata().valueOr:
      raiseAssert $error

    assert metadataOpt.isSome(), "metadata is not set"
    let metadata = metadataOpt.get()
    check:
      metadata.lastProcessedBlock == 128
      metadata.chainId == 1155511
      metadata.contractAddress == "0x9c09146844c1326c2dbc41c451766c7138f88155"

  test "getMetadata: empty rln metadata":
    # create an RLN instance which also includes an empty Merkle tree
    let rln = createRLNInstanceWrapper().valueOr:
      raiseAssert $error
    let metadata = rln.getMetadata().valueOr:
      raiseAssert $error

    check:
      metadata.isNone()

  test "Merkle tree consistency check between deletion and insertion":
    # create an RLN instance
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()

    let rln = rlnInstance.get()

    # read the Merkle Tree root
    let
      root1 {.noinit.}: Buffer = Buffer()
      rootPtr1 = unsafeAddr(root1)
      getRootSuccessful1 = getRoot(rln, rootPtr1)
    require:
      getRootSuccessful1
      root1.len == 32

    # generate an identity credential
    let idCredentialRes = membershipKeyGen(rln)
    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()
    let pkBuffer = toBuffer(idCredential.idCommitment)
    let pkBufferPtr = unsafeAddr(pkBuffer)

    # add the member to the tree
    let memberAdded = updateNextMember(rln, pkBufferPtr)
    require:
      memberAdded

    # read the Merkle Tree root after insertion
    let
      root2 {.noinit.}: Buffer = Buffer()
      rootPtr2 = unsafeAddr(root2)
      getRootSuccessful = getRoot(rln, rootPtr2)
    require:
      getRootSuccessful
      root2.len == 32

    # delete the first member
    let deletedMemberIndex = MembershipIndex(0)
    let deletionSuccess = deleteMember(rln, deletedMemberIndex)
    require:
      deletionSuccess

    # read the Merkle Tree root after the deletion
    let
      root3 {.noinit.}: Buffer = Buffer()
      rootPtr3 = unsafeAddr(root3)
      getRootSuccessful3 = getRoot(rln, rootPtr3)
    require:
      getRootSuccessful3
      root3.len == 32

    let rootValue1 = cast[ptr array[32, byte]](root1.`ptr`)
    let rootHex1 = rootValue1[].inHex
    debug "The initial root", rootHex1

    let rootValue2 = cast[ptr array[32, byte]](root2.`ptr`)
    let rootHex2 = rootValue2[].inHex
    debug "The root after insertion", rootHex2

    let rootValue3 = cast[ptr array[32, byte]](root3.`ptr`)
    let rootHex3 = rootValue3[].inHex
    debug "The root after deletion", rootHex3

    # the root must change after the insertion
    check:
      not (rootHex1 == rootHex2)

    ## The initial root of the tree (empty tree) must be identical to
    ## the root of the tree after one insertion followed by a deletion
    check:
      rootHex1 == rootHex3

  test "Merkle tree consistency check between deletion and insertion using rln utils":
    # create an RLN instance
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()

    let rln = rlnInstance.get()

    # read the Merkle Tree root
    let root1 = rln.getMerkleRoot()
    require:
      root1.isOk()
    let rootHex1 = root1.value().inHex()

    # generate an identity credential
    let idCredentialRes = rln.membershipKeyGen()
    require:
      idCredentialRes.isOk()
    let memberInserted = rln.insertMembers(0, @[idCredentialRes.get().idCommitment])
    require:
      memberInserted

    # read the Merkle Tree root after insertion
    let root2 = rln.getMerkleRoot()
    require:
      root2.isOk()
    let rootHex2 = root2.value().inHex()

    # delete the first member
    let deletedMemberIndex = MembershipIndex(0)
    let deletionSuccess = rln.removeMember(deletedMemberIndex)
    require:
      deletionSuccess

    # read the Merkle Tree root after the deletion
    let root3 = rln.getMerkleRoot()
    require:
      root3.isOk()
    let rootHex3 = root3.value().inHex()

    debug "The initial root", rootHex1
    debug "The root after insertion", rootHex2
    debug "The root after deletion", rootHex3

    # the root must change after the insertion
    check:
      not (rootHex1 == rootHex2)

    ## The initial root of the tree (empty tree) must be identical to
    ## the root of the tree after one insertion followed by a deletion
    check:
      rootHex1 == rootHex3

  test "hash Nim Wrappers":
    # create an RLN instance
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()

    # prepare the input
    let
      msg = "Hello".toBytes()
      hashInput = encodeLengthPrefix(msg)
      hashInputBuffer = toBuffer(hashInput)

    # prepare other inputs to the hash function
    let outputBuffer = default(Buffer)

    let hashSuccess = sha256(unsafeAddr hashInputBuffer, unsafeAddr outputBuffer)
    require:
      hashSuccess
    let outputArr = cast[ptr array[32, byte]](outputBuffer.`ptr`)[]

    check:
      "1e32b3ab545c07c8b4a7ab1ca4f46bc31e4fdc29ac3b240ef1d54b4017a26e4c" ==
        outputArr.inHex()

    let
      hashOutput = cast[ptr array[32, byte]](outputBuffer.`ptr`)[]
      hashOutputHex = hashOutput.toHex()

    debug "hash output", hashOutputHex

  test "sha256 hash utils":
    # create an RLN instance
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    # prepare the input
    let msg = "Hello".toBytes()

    let hashRes = sha256(msg)

    check:
      hashRes.isOk()
      "1e32b3ab545c07c8b4a7ab1ca4f46bc31e4fdc29ac3b240ef1d54b4017a26e4c" ==
        hashRes.get().inHex()

  test "poseidon hash utils":
    # create an RLN instance
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    # prepare the input
    let msg =
      @[
        "126f4c026cd731979365f79bd345a46d673c5a3f6f588bdc718e6356d02b6fdc".toBytes(),
        "1f0e5db2b69d599166ab16219a97b82b662085c93220382b39f9f911d3b943b1".toBytes(),
      ]

    let hashRes = poseidon(msg)

    # Value taken from zerokit
    check:
      hashRes.isOk()
      "28a15a991fe3d2a014485c7fa905074bfb55c0909112f865ded2be0a26a932c3" ==
        hashRes.get().inHex()

  test "create a list of membership keys and construct a Merkle tree based on the list":
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let
      groupSize = 100
      memListRes = rln.createMembershipList(groupSize)

    require:
      memListRes.isOk()

    let (list, root) = memListRes.get()

    debug "created membership key list", list
    debug "the Merkle tree root", root

    check:
      list.len == groupSize # check the number of keys
      root.len == HashHexSize # check the size of the calculated tree root

  test "check correctness of toIdentityCredentials":
    let groupKeys = StaticGroupKeys

    # create a set of IdentityCredentials objects from groupKeys
    let groupIdCredentialsRes = groupKeys.toIdentityCredentials()
    require:
      groupIdCredentialsRes.isOk()

    let groupIdCredentials = groupIdCredentialsRes.get()
    # extract the id commitments
    let groupIDCommitments = groupIdCredentials.mapIt(it.idCommitment)
    # calculate the Merkle tree root out of the extracted id commitments
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    # create a Merkle tree
    let rateCommitments =
      groupIDCommitments.mapIt(RateCommitment(idCommitment: it, userMessageLimit: 20))
    let leaves = rateCommitments.toLeaves().valueOr:
      raiseAssert $error
    let membersAdded = rln.insertMembers(0, leaves)

    assert membersAdded, "members should be added"
    let rawRoot = rln.getMerkleRoot().valueOr:
      raiseAssert $error

    let root = rawRoot.inHex()

    debug "groupIdCredentials", groupIdCredentials
    debug "groupIDCommitments",
      groupIDCommitments = groupIDCommitments.mapIt(it.inHex())
    debug "root", root

    check:
      # check that the correct number of identity credentials is created
      groupIdCredentials.len == StaticGroupSize
      # compare the calculated root against the correct root
      root == StaticGroupMerkleRoot

  test "RateLimitProof Protobuf encode/init test":
    var
      proof: ZKSNARK
      merkleRoot: MerkleNode
      epoch: Epoch
      shareX: MerkleNode
      shareY: MerkleNode
      nullifier: Nullifier
      rlnIdentifier: RlnIdentifier

    # populate fields with dummy values
    for x in proof.mitems:
      x = 1
    for x in merkleRoot.mitems:
      x = 2
    for x in epoch.mitems:
      x = 3
    for x in shareX.mitems:
      x = 4
    for x in shareY.mitems:
      x = 5
    for x in nullifier.mitems:
      x = 6
    for x in rlnIdentifier.mitems:
      x = 7

    let
      rateLimitProof = RateLimitProof(
        proof: proof,
        merkleRoot: merkleRoot,
        epoch: epoch,
        shareX: shareX,
        shareY: shareY,
        nullifier: nullifier,
        rlnIdentifier: rlnIdentifier,
      )
      protobuf = rateLimitProof.encode()
      decodednsp = RateLimitProof.init(protobuf.buffer)

    require:
      decodednsp.isOk()
    check:
      decodednsp.value == rateLimitProof

  test "toEpoch and fromEpoch consistency check":
    # check edge cases
    let
      epoch = uint64.high # rln epoch
      epochBytes = epoch.toEpoch()
      decodedEpoch = epochBytes.fromEpoch()
    check:
      epoch == decodedEpoch
    debug "encoded and decode time",
      epoch = epoch, epochBytes = epochBytes, decodedEpoch = decodedEpoch

  test "Epoch comparison, epoch1 > epoch2":
    # check edge cases
    let
      time1 = uint64.high
      time2 = uint64.high - 1
      epoch1 = time1.toEpoch()
      epoch2 = time2.toEpoch()
    check:
      absDiff(epoch1, epoch2) == uint64(1)
      absDiff(epoch2, epoch1) == uint64(1)

  test "updateLog and hasDuplicate tests":
    let
      wakuRlnRelay = WakuRLNRelay()
      epoch = wakuRlnRelay.getCurrentEpoch()

    #  create some dummy nullifiers and secret shares
    var nullifier1: Nullifier
    for index, x in nullifier1.mpairs:
      nullifier1[index] = 1
    var shareX1: MerkleNode
    for index, x in shareX1.mpairs:
      shareX1[index] = 1
    let shareY1 = shareX1

    var nullifier2: Nullifier
    for index, x in nullifier2.mpairs:
      nullifier2[index] = 2
    var shareX2: MerkleNode
    for index, x in shareX2.mpairs:
      shareX2[index] = 2
    let shareY2 = shareX2

    let nullifier3 = nullifier1
    var shareX3: MerkleNode
    for index, x in shareX3.mpairs:
      shareX3[index] = 3
    let shareY3 = shareX3

    proc encodeAndGetBuf(proof: RateLimitProof): seq[byte] =
      return proof.encode().buffer

    let
      proof1 = RateLimitProof(
        epoch: epoch, nullifier: nullifier1, shareX: shareX1, shareY: shareY1
      )
      wm1 = WakuMessage(proof: proof1.encodeAndGetBuf())
      proof2 = RateLimitProof(
        epoch: epoch, nullifier: nullifier2, shareX: shareX2, shareY: shareY2
      )
      wm2 = WakuMessage(proof: proof2.encodeAndGetBuf())
      proof3 = RateLimitProof(
        epoch: epoch, nullifier: nullifier3, shareX: shareX3, shareY: shareY3
      )
      wm3 = WakuMessage(proof: proof3.encodeAndGetBuf())

    # check whether hasDuplicate correctly finds records with the same nullifiers but different secret shares
    # no duplicate for proof1 should be found, since the log is empty
    let proofMetadata1 = proof1.extractMetadata().tryGet()
    let isDuplicate1 = wakuRlnRelay.hasDuplicate(epoch, proofMetadata1).valueOr:
      raiseAssert $error
    assert isDuplicate1 == false, "no duplicate should be found"
    #  add it to the log
    discard wakuRlnRelay.updateLog(epoch, proofMetadata1)

    # no duplicate for proof2 should be found, its nullifier differs from proof1
    let proofMetadata2 = proof2.extractMetadata().tryGet()
    let isDuplicate2 = wakuRlnRelay.hasDuplicate(epoch, proofMetadata2).valueOr:
      raiseAssert $error
    # no duplicate is found
    assert isDuplicate2 == false, "no duplicate should be found"
    #  add it to the log
    discard wakuRlnRelay.updateLog(epoch, proofMetadata2)

    #  proof3 has the same nullifier as proof1 but different secret shares, it should be detected as duplicate
    let isDuplicate3 = wakuRlnRelay.hasDuplicate(
      epoch, proof3.extractMetadata().tryGet()
    ).valueOr:
      raiseAssert $error
    # it is a duplicate
    assert isDuplicate3, "duplicate should be found"

  asyncTest "validateMessageAndUpdateLog test":
    let index = MembershipIndex(5)

    let wakuRlnConfig = WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(index),
      rlnRelayUserMessageLimit: 1,
      rlnEpochSizeSec: 1,
      rlnRelayTreePath: genTempPath("rln_tree", "waku_rln_relay_2"),
    )

    let wakuRlnRelay = (await WakuRlnRelay.new(wakuRlnConfig)).valueOr:
      raiseAssert $error

    # get the current epoch time
    let time = epochTime()

    #  create some messages from the same peer and append rln proof to them, except wm4
    var
      wm1 = WakuMessage(payload: "Valid message".toBytes())
      # another message in the same epoch as wm1, it will break the messaging rate limit
      wm2 = WakuMessage(payload: "Spam".toBytes())
      #  wm3 points to the next epoch
      wm3 = WakuMessage(payload: "Valid message".toBytes())
      wm4 = WakuMessage(payload: "Invalid message".toBytes())

    wakuRlnRelay.unsafeAppendRLNProof(wm1, time).isOkOr:
      raiseAssert $error
    wakuRlnRelay.unsafeAppendRLNProof(wm2, time).isOkOr:
      raiseAssert $error
    wakuRlnRelay.unsafeAppendRLNProof(wm3, time + float64(wakuRlnRelay.rlnEpochSizeSec)).isOkOr:
      raiseAssert $error

    # validate messages
    # validateMessage proc checks the validity of the message fields and adds it to the log (if valid)
    let
      msgValidate1 = wakuRlnRelay.validateMessageAndUpdateLog(wm1, some(time))
      # wm2 is published within the same Epoch as wm1 and should be found as spam
      msgValidate2 = wakuRlnRelay.validateMessageAndUpdateLog(wm2, some(time))
      # a valid message should be validated successfully
      msgValidate3 = wakuRlnRelay.validateMessageAndUpdateLog(wm3, some(time))
      # wm4 has no rln proof and should not be validated
      msgValidate4 = wakuRlnRelay.validateMessageAndUpdateLog(wm4, some(time))

    check:
      msgValidate1 == MessageValidationResult.Valid
      msgValidate2 == MessageValidationResult.Spam
      msgValidate3 == MessageValidationResult.Valid
      msgValidate4 == MessageValidationResult.Invalid

  asyncTest "validateMessageAndUpdateLog: multiple senders with same external nullifier":
    let index1 = MembershipIndex(5)
    let index2 = MembershipIndex(6)

    let rlnConf1 = WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(index1),
      rlnRelayUserMessageLimit: 1,
      rlnEpochSizeSec: 1,
      rlnRelayTreePath: genTempPath("rln_tree", "waku_rln_relay_3"),
    )

    let wakuRlnRelay1 = (await WakuRlnRelay.new(rlnConf1)).valueOr:
      raiseAssert "failed to create waku rln relay: " & $error

    let rlnConf2 = WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(index2),
      rlnRelayUserMessageLimit: 1,
      rlnEpochSizeSec: 1,
      rlnRelayTreePath: genTempPath("rln_tree", "waku_rln_relay_4"),
    )

    let wakuRlnRelay2 = (await WakuRlnRelay.new(rlnConf2)).valueOr:
      raiseAssert "failed to create waku rln relay: " & $error
    # get the current epoch time
    let time = epochTime()

    #  create messages from different peers and append rln proofs to them
    var
      wm1 = WakuMessage(payload: "Valid message from sender 1".toBytes())
      # another message in the same epoch as wm1, it will break the messaging rate limit
      wm2 = WakuMessage(payload: "Valid message from sender 2".toBytes())

    wakuRlnRelay1.appendRLNProof(wm1, time).isOkOr:
      raiseAssert $error
    wakuRlnRelay2.appendRLNProof(wm2, time).isOkOr:
      raiseAssert $error

    # validate messages
    # validateMessage proc checks the validity of the message fields and adds it to the log (if valid)
    let
      msgValidate1 = wakuRlnRelay1.validateMessageAndUpdateLog(wm1, some(time))
      # since this message is from a different sender, it should be validated successfully
      msgValidate2 = wakuRlnRelay1.validateMessageAndUpdateLog(wm2, some(time))

    check:
      msgValidate1 == MessageValidationResult.Valid
      msgValidate2 == MessageValidationResult.Valid

  test "toIDCommitment and toUInt256":
    # create an instance of rln
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()

    let rln = rlnInstance.get()

    # create an idendity credential
    let idCredentialRes = rln.membershipKeyGen()
    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()

    # convert the idCommitment to UInt256
    let idCUInt = idCredential.idCommitment.toUInt256()
    # convert the UInt256 back to ICommitment
    let idCommitment = toIDCommitment(idCUInt)

    # check that the conversion has not distorted the original value
    check:
      idCredential.idCommitment == idCommitment

  test "Read/Write RLN credentials":
    # create an RLN instance
    let rlnInstance = createRLNInstanceWrapper()
    require:
      rlnInstance.isOk()

    let idCredentialRes = membershipKeyGen(rlnInstance.get())
    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()
    let empty = default(array[32, byte])
    require:
      idCredential.idTrapdoor.len == 32
      idCredential.idNullifier.len == 32
      idCredential.idSecretHash.len == 32
      idCredential.idCommitment.len == 32
      idCredential.idTrapdoor != empty
      idCredential.idNullifier != empty
      idCredential.idSecretHash != empty
      idCredential.idCommitment != empty

    debug "the generated identity credential: ", idCredential

    let index = MembershipIndex(1)

    let keystoreMembership = KeystoreMembership(
      membershipContract: MembershipContract(
        chainId: "5", address: "0x0123456789012345678901234567890123456789"
      ),
      treeIndex: index,
      identityCredential: idCredential,
    )
    let password = "%m0um0ucoW%"

    let filepath = "./testRLNCredentials.txt"
    defer:
      removeFile(filepath)

    # Write RLN credentials
    require:
      addMembershipCredentials(
        path = filepath,
        membership = keystoreMembership,
        password = password,
        appInfo = RLNAppInfo,
      )
      .isOk()

    let readKeystoreRes = getMembershipCredentials(
      path = filepath,
      password = password,
      # here the query would not include
      # the identityCredential,
      # since it is not part of the query
      # but have used the same value
      # to avoid re-declaration
      query = keystoreMembership,
      appInfo = RLNAppInfo,
    )
    assert readKeystoreRes.isOk(), $readKeystoreRes.error

    # getMembershipCredentials returns the credential in the keystore which matches
    # the query, in this case the query is =
    # chainId = "5" and
    # address = "0x0123456789012345678901234567890123456789" and
    # treeIndex = 1
    let readKeystoreMembership = readKeystoreRes.get()
    check:
      readKeystoreMembership == keystoreMembership

  test "histogram static bucket generation":
    let buckets = generateBucketsForHistogram(10)

    check:
      buckets.len == 5
      buckets == [2.0, 4.0, 6.0, 8.0, 10.0]
  
  asyncTest "nullifierLog clearing only after epoch has passed":
    let index = MembershipIndex(0)

    proc runTestForEpochSizeSec(rlnEpochSizeSec: uint) {.async.} =
      let wakuRlnConfig = WakuRlnConfig(
        rlnRelayDynamic: false,
        rlnRelayCredIndex: some(index),
        rlnRelayUserMessageLimit: 1,
        rlnEpochSizeSec: rlnEpochSizeSec,
        rlnRelayTreePath: genTempPath("rln_tree", "waku_rln_relay_4"),
      )

      let wakuRlnRelay = (await WakuRlnRelay.new(wakuRlnConfig)).valueOr:
        raiseAssert $error

      let rlnMaxEpochGap = wakuRlnRelay.rlnMaxEpochGap
      let testProofMetadata = default(ProofMetadata)
      let testProofMetadataTable = {testProofMetadata.nullifier: testProofMetadata}.toTable()

      for i in 0..rlnMaxEpochGap:
        # we add epochs to the nullifierLog
        let testEpoch =  wakuRlnRelay.calcEpoch(epochTime() + float(rlnEpochSizeSec * i))
        wakuRlnRelay.nullifierLog[testEpoch] = testProofMetadataTable
        check: wakuRlnRelay.nullifierLog.len().uint == i + 1

      check: wakuRlnRelay.nullifierLog.len().uint == rlnMaxEpochGap + 1

      # clearing it now will remove 1 epoch
      wakuRlnRelay.clearNullifierLog()

      check: wakuRlnRelay.nullifierLog.len().uint == rlnMaxEpochGap

    var testEpochSizes: seq[uint] = @[1,5,10,30,60,600]
    for i in testEpochSizes:
      await runTestForEpochSizeSec(i)

