
{.used.}

import
  std/[options, os, sequtils, times],
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  chronicles,
  stint,
  libp2p/crypto/crypto
import
  ../../waku/v2/node/waku_node,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_rln_relay,
  ../../waku/v2/protocol/waku_keystore,
  ./testlib/waku2

const RlnRelayPubsubTopic = "waku/2/rlnrelay/proto"
const RlnRelayContentTopic = "waku/2/rlnrelay/proto"


suite "Waku rln relay":

  asyncTest "mount waku-rln-relay in the off-chain mode":
    let
      nodeKey = generateSecp256k1Key()
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(0))
    await node.start()

    # preparing inputs to mount rln-relay

    # create a group of 100 membership keys
    let memListRes = createMembershipList(100)
    require:
      memListRes.isOk()

    let (groupCredentials, root) = memListRes.get()
    require:
      groupCredentials.len == 100
    let
      # convert the keys to IdentityCredential structs
      groupIdCredentialsRes = groupCredentials.toIdentityCredentials()
    require:
      groupIdCredentialsRes.isOk()

    let
      groupIdCredentials = groupIdCredentialsRes.get()
      # extract the id commitments
      groupIDCommitments = groupIdCredentials.mapIt(it.idCommitment)
    debug "groupIdCredentials", groupIdCredentials
    debug "groupIDCommitments", groupIDCommitments

    # index indicates the position of a membership credential in the static list of group keys i.e., groupIdCredentials
    # the corresponding credential will be used to mount rlnRelay on the current node
    # index also represents the index of the leaf in the Merkle tree that contains node's commitment key
    let index = MembershipIndex(5)

    # -------- mount rln-relay in the off-chain mode
    await node.mountRelay(@[RlnRelayPubsubTopic])
    let mountRes = node.wakuRelay.mountRlnRelayStatic(group = groupIDCommitments,
                            memIdCredential = groupIdCredentials[index],
                            memIndex = index,
                            pubsubTopic = RlnRelayPubsubTopic,
                            contentTopic = RlnRelayContentTopic)
    require:
      mountRes.isOk()

    let wakuRlnRelay = mountRes.get()

    # get the root of Merkle tree which is constructed inside the mountRlnRelay proc
    let calculatedRootRes = wakuRlnRelay.rlnInstance.getMerkleRoot()
    require:
      calculatedRootRes.isOk()
    let calculatedRoot = calculatedRootRes.get().inHex()
    debug "calculated root by mountRlnRelay", calculatedRoot

    # this part checks whether the Merkle tree is constructed correctly inside the mountRlnRelay proc
    # this check is done by comparing the tree root resulted from mountRlnRelay i.e., calculatedRoot
    # against the root which is the expected root
    check:
      calculatedRoot == root

    await node.stop()

suite "Waku rln relay":

  test "key_gen Nim Wrappers":
    let
      merkleDepth: csize_t = 20

    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()

    # keysBufferPtr will hold the generated identity credential i.e., id trapdoor, nullifier, secret hash and commitment
    var
      keysBuffer: Buffer
    let
      keysBufferPtr = addr(keysBuffer)
      done = key_gen(rlnInstance.get(), keysBufferPtr)
    require:
      # check whether the keys are generated successfully
      done

    let generatedKeys = cast[ptr array[4*32, byte]](keysBufferPtr.`ptr`)[]
    check:
      # the id trapdoor, nullifier, secert hash and commitment together are 4*32 bytes
      generatedKeys.len == 4*32
    debug "generated keys: ", generatedKeys

  test "membership Key Generation":
    # create an RLN instance
    let rlnInstance = createRLNInstance()
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
    let rlnInstance = createRLNInstance()
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

    let rootValue1 = cast[ptr array[32, byte]] (root1.`ptr`)
    let rootHex1 = rootValue1[].inHex

    let rootValue2 = cast[ptr array[32, byte]] (root2.`ptr`)
    let rootHex2 = rootValue2[].inHex

    # the two roots must be identical
    check:
      rootHex1 == rootHex2
  test "getMerkleRoot utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstance()
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
    let rlnInstance = createRLNInstance()
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

  test "delete_member Nim wrapper":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()

    # delete the first member
    let deletedMemberIndex = MembershipIndex(0)
    let deletionSuccess = deleteMember(rlnInstance.get(), deletedMemberIndex)
    check:
      deletionSuccess

  test "insertMembers rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()
    # generate an identity credential
    let idCredentialRes = rln.membershipKeyGen()
    require:
      idCredentialRes.isOk()
    check:
      rln.insertMembers(0, @[idCredentialRes.get().idCommitment])

  test "insertMember rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstance()
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
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()
    check:
      rln.removeMember(MembershipIndex(0))

  test "Merkle tree consistency check between deletion and insertion":
    # create an RLN instance
    let rlnInstance = createRLNInstance()
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

    let rootValue1 = cast[ptr array[32, byte]] (root1.`ptr`)
    let rootHex1 = rootValue1[].inHex
    debug "The initial root", rootHex1

    let rootValue2 = cast[ptr array[32, byte]] (root2.`ptr`)
    let rootHex2 = rootValue2[].inHex
    debug "The root after insertion", rootHex2

    let rootValue3 = cast[ptr array[32, byte]] (root3.`ptr`)
    let rootHex3 = rootValue3[].inHex
    debug "The root after deletion", rootHex3

    # the root must change after the insertion
    check:
      not(rootHex1 == rootHex2)

    ## The initial root of the tree (empty tree) must be identical to
    ## the root of the tree after one insertion followed by a deletion
    check:
      rootHex1 == rootHex3

  test "Merkle tree consistency check between deletion and insertion using rln utils":
    # create an RLN instance
    let rlnInstance = createRLNInstance()
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
      not(rootHex1 == rootHex2)

    ## The initial root of the tree (empty tree) must be identical to
    ## the root of the tree after one insertion followed by a deletion
    check:
      rootHex1 == rootHex3

  test "hash Nim Wrappers":
    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()

    # prepare the input
    let
      msg = "Hello".toBytes()
      hashInput = appendLength(msg)
      hashInputBuffer = toBuffer(hashInput)

    # prepare other inputs to the hash function
    let outputBuffer = default(Buffer)

    let hashSuccess = hash(rlnInstance.get(), unsafeAddr hashInputBuffer,
        unsafeAddr outputBuffer)
    require:
      hashSuccess
    let outputArr = cast[ptr array[32, byte]](outputBuffer.`ptr`)[]

    check:
      "1e32b3ab545c07c8b4a7ab1ca4f46bc31e4fdc29ac3b240ef1d54b4017a26e4c" ==
        outputArr.inHex()

    let
      hashOutput = cast[ptr array[32, byte]] (outputBuffer.`ptr`)[]
      hashOutputHex = hashOutput.toHex()

    debug "hash output", hashOutputHex

  test "hash utils":
    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    # prepare the input
    let msg = "Hello".toBytes()

    let hash = rln.hash(msg)

    check:
      "1e32b3ab545c07c8b4a7ab1ca4f46bc31e4fdc29ac3b240ef1d54b4017a26e4c" ==
        hash.inHex()

  test "create a list of membership keys and construct a Merkle tree based on the list":
    let
      groupSize = 100
      memListRes = createMembershipList(groupSize)

    require:
      memListRes.isOk()

    let (list, root) = memListRes.get()

    debug "created membership key list", list
    debug "the Merkle tree root", root

    check:
      list.len == groupSize # check the number of keys
      root.len == HashHexSize # check the size of the calculated tree root

  test "check correctness of toIdentityCredentials and calcMerkleRoot":
    let groupKeys = StaticGroupKeys

    # create a set of IdentityCredentials objects from groupKeys
    let groupIdCredentialsRes = groupKeys.toIdentityCredentials()
    require:
      groupIdCredentialsRes.isOk()

    let groupIdCredentials = groupIdCredentialsRes.get()
    # extract the id commitments
    let groupIDCommitments = groupIdCredentials.mapIt(it.idCommitment)
    # calculate the Merkle tree root out of the extracted id commitments
    let rootRes = calcMerkleRoot(groupIDCommitments)

    require:
      rootRes.isOk()

    let root = rootRes.get()

    debug "groupIdCredentials", groupIdCredentials
    debug "groupIDCommitments", groupIDCommitments
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
    for x in proof.mitems: x = 1
    for x in merkleRoot.mitems: x = 2
    for x in epoch.mitems: x = 3
    for x in shareX.mitems: x = 4
    for x in shareY.mitems: x = 5
    for x in nullifier.mitems: x = 6
    for x in rlnIdentifier.mitems: x = 7

    let
      rateLimitProof = RateLimitProof(proof: proof,
                          merkleRoot: merkleRoot,
                          epoch: epoch,
                          shareX: shareX,
                          shareY: shareY,
                          nullifier: nullifier,
                          rlnIdentifier: rlnIdentifier)
      protobuf = rateLimitProof.encode()
      decodednsp = RateLimitProof.init(protobuf.buffer)

    require:
      decodednsp.isOk()
    check:
      decodednsp.value == rateLimitProof

  test "test proofVerify and proofGen for a valid proof":
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let
      # peer's index in the Merkle Tree
      index = 5'u
      # create an identity credential
      idCredentialRes = membershipKeyGen(rln)

    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()

    var members = newSeq[IDCommitment]()
    # Create a Merkle tree with random members
    for i in 0'u..10'u:
      if (i == index):
        # insert the current peer's pk
        members.add(idCredential.idCommitment)
      else:
        # create a new identity credential
        let idCredentialRes = rln.membershipKeyGen()
        require:
          idCredentialRes.isOk()
        members.add(idCredentialRes.get().idCommitment)

    # Batch the insert
    let batchInsertRes = rln.insertMembers(0, members)
    require:
      batchInsertRes

    # prepare the message
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch", epochHex = epoch.inHex()

    # generate proof
    let proofRes = rln.proofGen(data = messageBytes,
                                memKeys = idCredential,
                                memIndex = MembershipIndex(index),
                                epoch = epoch)
    require:
      proofRes.isOk()
    let proof = proofRes.value

    # verify the proof
    let verified = rln.proofVerify(data = messageBytes,
                                   proof = proof,
                                   validRoots = @[rln.getMerkleRoot().value()])

    # Ensure the proof verification did not error out

    require:
      verified.isOk()

    check:
      verified.value() == true

  test "test proofVerify and proofGen for an invalid proof":
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let
      # peer's index in the Merkle Tree
      index = 5'u
      # create an identity credential
      idCredentialRes = membershipKeyGen(rln)

    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()

    # Create a Merkle tree with random members
    for i in 0'u..10'u:
      var memberAdded: bool = false
      if (i == index):
        # insert the current peer's pk
        memberAdded = rln.insertMembers(i, @[idCredential.idCommitment])
      else:
        # create a new identity credential
        let idCredentialRes = rln.membershipKeyGen()
        require:
          idCredentialRes.isOk()
        memberAdded = rln.insertMembers(i, @[idCredentialRes.get().idCommitment])
      # check the member is added
      require:
        memberAdded

    # prepare the message
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()


    let badIndex = 4
    # generate proof
    let proofRes = rln.proofGen(data = messageBytes,
                                memKeys = idCredential,
                                memIndex = MembershipIndex(badIndex),
                                epoch = epoch)
    require:
      proofRes.isOk()
    let proof = proofRes.value

    # verify the proof (should not be verified) against the internal RLN tree root
    let verified = rln.proofVerify(data = messageBytes,
                                  proof = proof,
                                  validRoots = @[rln.getMerkleRoot().value()])

    require:
      verified.isOk()
    check:
      verified.value() == false

  test "validate roots which are part of the acceptable window":
    # Setup:
    # This step consists of creating the rln instance and waku-rln-relay,
    # Inserting members, and creating a valid proof with the merkle root
    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let rlnRelay = WakuRLNRelay(rlnInstance:rln)

    let
      # peer's index in the Merkle Tree.
      index = 5'u
      # create an identity credential
      idCredentialRes = membershipKeyGen(rlnRelay.rlnInstance)

    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()

    let membershipCount: uint = AcceptableRootWindowSize + 5'u

    var members = newSeq[IdentityCredential]()

    # Generate membership keys
    for i in 0'u..membershipCount:
      if (i == index):
        # insert the current peer's pk
        members.add(idCredential)
      else:
        # create a new identity credential
        let idCredentialRes = rlnRelay.rlnInstance.membershipKeyGen()
        require:
          idCredentialRes.isOk()
        members.add(idCredentialRes.get())

    # Batch inserts into the tree
    let insertedRes = rlnRelay.insertMembers(0, members.mapIt(it.idCommitment))
    require:
      insertedRes.isOk()

    # Given:
    # This step includes constructing a valid message with the latest merkle root
    # prepare the message
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = rlnRelay.rlnInstance.proofGen(data = messageBytes,
                                    memKeys = idCredential,
                                    memIndex = MembershipIndex(index),
                                    epoch = epoch)
    require:
      validProofRes.isOk()
    let validProof = validProofRes.value

    # validate the root (should be true)
    let verified = rlnRelay.validateRoot(validProof.merkleRoot)

    require:
      verified == true

    # When:
    # This test depends on the local merkle tree root being part of a
    # acceptable set of roots, which is denoted by AcceptableRootWindowSize
    # The following action is equivalent to a member being removed upon listening to the events emitted by the contract

    # Progress the local tree by removing members
    for i in 0..AcceptableRootWindowSize - 2:
      let res = rlnRelay.removeMember(MembershipIndex(i))
      # Ensure the local tree root has changed
      let currentMerkleRoot = rlnRelay.rlnInstance.getMerkleRoot()

      require:
        res.isOk()
        currentMerkleRoot.isOk()
        currentMerkleRoot.value() != validProof.merkleRoot

    # Then:
    # we try to verify a root against this window,
    # which should return true
    let olderRootVerified = rlnRelay.validateRoot(validProof.merkleRoot)

    check:
      olderRootVerified == true

  test "invalidate roots which are not part of the acceptable window":
    # Setup:
    # This step consists of creating the rln instance and waku-rln-relay,
    # Inserting members, and creating a valid proof with the merkle root

    require:
      AcceptableRootWindowSize < 10

    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let rlnRelay = WakuRLNRelay(rlnInstance:rln)

    let
      # peer's index in the Merkle Tree.
      index = 6'u
      # create an identity credential
      idCredentialRes = membershipKeyGen(rlnRelay.rlnInstance)

    require:
      idCredentialRes.isOk()

    let idCredential = idCredentialRes.get()

    let membershipCount: uint = AcceptableRootWindowSize + 5'u

    # Create a Merkle tree with random members
    for i in 0'u..membershipCount:
      var memberIsAdded: RlnRelayResult[void]
      if (i == index):
        # insert the current peer's pk
        memberIsAdded = rlnRelay.insertMembers(i, @[idCredential.idCommitment])
      else:
        # create a new identity credential
        let idCredentialRes = rlnRelay.rlnInstance.membershipKeyGen()
        require:
          idCredentialRes.isOk()
        memberIsAdded = rlnRelay.insertMembers(i, @[idCredentialRes.get().idCommitment])
      # require that the member is added
      require:
        memberIsAdded.isOk()

    # Given:
    # This step includes constructing a valid message with the latest merkle root
    # prepare the message
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    let epoch = default(Epoch)
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = rlnRelay.rlnInstance.proofGen(data = messageBytes,
                                    memKeys = idCredential,
                                    memIndex = MembershipIndex(index),
                                    epoch = epoch)
    require:
      validProofRes.isOk()
    let validProof = validProofRes.value

    # validate the root (should be true)
    let verified = rlnRelay.validateRoot(validProof.merkleRoot)

    require:
      verified == true

    # When:
    # This test depends on the local merkle tree root being part of a
    # acceptable set of roots, which is denoted by AcceptableRootWindowSize
    # The following action is equivalent to a member being removed upon listening to the events emitted by the contract

    # Progress the local tree by removing members
    for i in 0..AcceptableRootWindowSize:
      discard rlnRelay.removeMember(MembershipIndex(i))
      # Ensure the local tree root has changed
      let currentMerkleRoot = rlnRelay.rlnInstance.getMerkleRoot()
      require:
        currentMerkleRoot.isOk()
        currentMerkleRoot.value() != validProof.merkleRoot

    # Then:
    # we try to verify a proof against this window,
    # which should return false
    let olderRootVerified = rlnRelay.validateRoot(validProof.merkleRoot)

    check:
      olderRootVerified == false

  test "toEpoch and fromEpoch consistency check":
    # check edge cases
    let
      epoch = uint64.high # rln epoch
      epochBytes = epoch.toEpoch()
      decodedEpoch = epochBytes.fromEpoch()
    check:
      epoch == decodedEpoch
    debug "encoded and decode time", epoch = epoch, epochBytes = epochBytes,
      decodedEpoch = decodedEpoch

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
      wakurlnrelay = WakuRLNRelay()
      epoch = getCurrentEpoch()

    #  create some dummy nullifiers and secret shares
    var nullifier1: Nullifier
    for index, x in nullifier1.mpairs: nullifier1[index] = 1
    var shareX1: MerkleNode
    for index, x in shareX1.mpairs: shareX1[index] = 1
    let shareY1 = shareX1

    var nullifier2: Nullifier
    for index, x in nullifier2.mpairs: nullifier2[index] = 2
    var shareX2: MerkleNode
    for index, x in shareX2.mpairs: shareX2[index] = 2
    let shareY2 = shareX2

    let nullifier3 = nullifier1
    var shareX3: MerkleNode
    for index, x in shareX3.mpairs: shareX3[index] = 3
    let shareY3 = shareX3

    proc encodeAndGetBuf(proof: RateLimitProof): seq[byte] =
      return proof.encode().buffer

    let
      wm1 = WakuMessage(proof: RateLimitProof(epoch: epoch,
                                              nullifier: nullifier1,
                                              shareX: shareX1,
                                              shareY: shareY1).encodeAndGetBuf())
      wm2 = WakuMessage(proof: RateLimitProof(epoch: epoch,
                                              nullifier: nullifier2,
                                              shareX: shareX2,
                                              shareY: shareY2).encodeAndGetBuf())
      wm3 = WakuMessage(proof: RateLimitProof(epoch: epoch,
                                              nullifier: nullifier3,
                                              shareX: shareX3,
                                              shareY: shareY3).encodeAndGetBuf())

    # check whether hasDuplicate correctly finds records with the same nullifiers but different secret shares
    # no duplicate for wm1 should be found, since the log is empty
    let result1 = wakurlnrelay.hasDuplicate(wm1)
    require:
      result1.isOk()
      # no duplicate is found
      result1.value == false
    #  add it to the log
    discard wakurlnrelay.updateLog(wm1)

    # # no duplicate for wm2 should be found, its nullifier differs from wm1
    let result2 = wakurlnrelay.hasDuplicate(wm2)
    require:
      result2.isOk()
      # no duplicate is found
      result2.value == false
    #  add it to the log
    discard wakurlnrelay.updateLog(wm2)

    #  wm3 has the same nullifier as wm1 but different secret shares, it should be detected as duplicate
    let result3 = wakurlnrelay.hasDuplicate(wm3)
    require:
      result3.isOk()
    check:
      # it is a duplicate
      result3.value == true

  test "validateMessage test":
    # setup a wakurlnrelay peer with a static group----------

    # create a group of 100 membership keys
    let memListRes = createMembershipList(100)

    require:
      memListRes.isOk()
    let
      (groupKeys, _) = memListRes.get()
      # convert the keys to IdentityCredential structs
      groupIdCredentialsRes = groupKeys.toIdentityCredentials()

    require:
      groupIdCredentialsRes.isOk()

    let groupIdCredentials = groupIdCredentialsRes.get()
    # extract the id commitments
    let groupIDCommitments = groupIdCredentials.mapIt(it.idCommitment)
    debug "groupIdCredentials", groupIdCredentials
    debug "groupIDCommitments", groupIDCommitments

    # index indicates the position of an identity credential in the static list of group keys i.e., groupIdCredentials
    # the corresponding identity credential will be used to mount rlnRelay on the current node
    # index also represents the index of the leaf in the Merkle tree that contains node's commitment key
    let index = MembershipIndex(5)

    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let
      wakuRlnRelay = WakuRLNRelay(membershipIndex: index,
          identityCredential: groupIdCredentials[index], rlnInstance: rln)

    # add members
    let commitmentAddRes =  wakuRlnRelay.addAll(groupIDCommitments)
    require:
      commitmentAddRes.isOk()

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

    let
      proofAdded1 = wakuRlnRelay.appendRLNProof(wm1, time)
      proofAdded2 = wakuRlnRelay.appendRLNProof(wm2, time)
      proofAdded3 = wakuRlnRelay.appendRLNProof(wm3, time+EpochUnitSeconds)

    # ensure proofs are added
    require:
      proofAdded1
      proofAdded2
      proofAdded3

    # validate messages
    # validateMessage proc checks the validity of the message fields and adds it to the log (if valid)
    let
      msgValidate1 = wakuRlnRelay.validateMessage(wm1, some(time))
      # wm2 is published within the same Epoch as wm1 and should be found as spam
      msgValidate2 = wakuRlnRelay.validateMessage(wm2, some(time))
      # a valid message should be validated successfully
      msgValidate3 = wakuRlnRelay.validateMessage(wm3, some(time))
      # wm4 has no rln proof and should not be validated
      msgValidate4 = wakuRlnRelay.validateMessage(wm4, some(time))


    check:
      msgValidate1 == MessageValidationResult.Valid
      msgValidate2 == MessageValidationResult.Spam
      msgValidate3 == MessageValidationResult.Valid
      msgValidate4 == MessageValidationResult.Invalid

  test "toIDCommitment and toUInt256":
    # create an instance of rln
    let rlnInstance = createRLNInstance()
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
    let rlnInstance = createRLNInstance()
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

    let rlnMembershipContract = MembershipContract(chainId: "5", address: "0x0123456789012345678901234567890123456789")
    let rlnMembershipGroup = MembershipGroup(membershipContract: rlnMembershipContract, treeIndex: index)
    let rlnMembershipCredentials = MembershipCredentials(identityCredential: idCredential, membershipGroups: @[rlnMembershipGroup])

    let password = "%m0um0ucoW%"

    let filepath = "./testRLNCredentials.txt"
    defer: removeFile(filepath)

    # Write RLN credentials
    require:
      addMembershipCredentials(path = filepath,
                                credentials = @[rlnMembershipCredentials],
                                password = password,
                                appInfo = RLNAppInfo).isOk()

    let readCredentialsResult = getMembershipCredentials(path = filepath,
                                                         password = password,
                                                         filterMembershipContracts = @[rlnMembershipContract],
                                                         appInfo = RLNAppInfo)

    require:
      readCredentialsResult.isOk()

    # getMembershipCredentials returns all credentials in keystore as sequence matching the filter
    let allMatchingCredentials = readCredentialsResult.get()
    # if any is found, we return the first credential, otherwise credentials is none
    var credentials = none(MembershipCredentials)
    if allMatchingCredentials.len() > 0:
      credentials = some(allMatchingCredentials[0])

    require:
      credentials.isSome()
    check:
      credentials.get().identityCredential == idCredential
      credentials.get().membershipGroups == @[rlnMembershipGroup]

  test "histogram static bucket generation":
    let buckets = generateBucketsForHistogram(10)

    check:
      buckets.len == 5
      buckets == [2.0, 4.0, 6.0, 8.0, 10.0]
