
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
  ../../waku/v2/protocol/waku_rln_relay/rln, 
  ../../waku/v2/protocol/waku_rln_relay/waku_rln_relay_utils,
  ../../waku/v2/protocol/waku_rln_relay/waku_rln_relay_types,
  ../../waku/v2/protocol/waku_rln_relay/waku_rln_relay_constants,
  ../../waku/v2/protocol/waku_rln_relay/waku_rln_relay_metrics,
  ../test_helpers

const RlnRelayPubsubTopic = "waku/2/rlnrelay/proto"
const RlnRelayContentTopic = "waku/2/rlnrelay/proto"

procSuite "Waku rln relay":
  asyncTest "mount waku-rln-relay in the off-chain mode":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60200))
    await node.start()

    # preparing inputs to mount rln-relay

    # create a group of 100 membership keys
    let memListRes = createMembershipList(100)
    require:
      memListRes.isOk()

    let (groupKeys, root) = memListRes.get()
    check:
      groupKeys.len == 100
    let
      # convert the keys to MembershipKeyPair structs
      groupKeyPairsRes = groupKeys.toMembershipKeyPairs()
    require:
      groupKeyPairsRes.isOk()
    
    let 
      groupKeyPairs = groupKeyPairsRes.get()
      # extract the id commitments
      groupIDCommitments = groupKeyPairs.mapIt(it.idCommitment)
    debug "groupKeyPairs", groupKeyPairs
    debug "groupIDCommitments", groupIDCommitments

    # index indicates the position of a membership key pair in the static list of group keys i.e., groupKeyPairs
    # the corresponding key pair will be used to mount rlnRelay on the current node
    # index also represents the index of the leaf in the Merkle tree that contains node's commitment key
    let index = MembershipIndex(5)

    # -------- mount rln-relay in the off-chain mode
    await node.mountRelay(@[RlnRelayPubsubTopic])
    let mountRes = node.mountRlnRelayStatic(group = groupIDCommitments,
                            memKeyPair = groupKeyPairs[index],
                            memIndex = index,
                            pubsubTopic = RlnRelayPubsubTopic,
                            contentTopic = RlnRelayContentTopic)
    require:
      mountRes.isOk()

    # get the root of Merkle tree which is constructed inside the mountRlnRelay proc
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().inHex
    debug "calculated root by mountRlnRelay", calculatedRoot

    # this part checks whether the Merkle tree is constructed correctly inside the mountRlnRelay proc
    # this check is done by comparing the tree root resulted from mountRlnRelay i.e., calculatedRoot
    # against the root which is the expected root
    check:
      calculatedRoot == root

    await node.stop()

suite "Waku rln relay":

  test "key_gen Nim Wrappers":
    var
      merkleDepth: csize_t = 20

    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()

    # keysBufferPtr will hold the generated key pairs i.e., secret and public keys
    var
      keysBuffer: Buffer
      keysBufferPtr = addr(keysBuffer)
      done = key_gen(rlnInstance.get(), keysBufferPtr)
    check:
      # check whether the keys are generated successfully
      done == true

    if done:
      var generatedKeys = cast[ptr array[64, byte]](keysBufferPtr.`ptr`)[]
      check:
        # the public and secret keys together are 64 bytes
        generatedKeys.len == 64
      debug "generated keys: ", generatedKeys

  test "membership Key Generation":
    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()

    let keyPairRes = membershipKeyGen(rlnInstance.get())
    require:
      keyPairRes.isOk()

    let keyPair = keyPairRes.get()
    var empty: array[32, byte]
    check:
      keyPair.idKey.len == 32
      keyPair.idCommitment.len == 32
      keyPair.idKey != empty
      keyPair.idCommitment != empty

    debug "the generated membership key pair: ", keyPair

  test "getRoot Nim binding":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()

    # read the Merkle Tree root
    var
      root1 {.noinit.}: Buffer = Buffer()
      rootPtr1 = addr(root1)
      getRootSuccessful1 = getRoot(rlnInstance.get(), rootPtr1)
    check:
      getRootSuccessful1
      root1.len == 32

    # read the Merkle Tree root
    var
      root2 {.noinit.}: Buffer = Buffer()
      rootPtr2 = addr(root2)
      getRootSuccessful2 = getRoot(rlnInstance.get(), rootPtr2)
    check:
      getRootSuccessful2
      root2.len == 32

    var rootValue1 = cast[ptr array[32, byte]] (root1.`ptr`)
    let rootHex1 = rootValue1[].inHex

    var rootValue2 = cast[ptr array[32, byte]] (root2.`ptr`)
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
    var root1 = getMerkleRoot(rln)
    require:
      root1.isOk()
    let rootHex1 = root1.value().inHex

    # read the Merkle Tree root
    var root2 = getMerkleRoot(rln)
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
    # generate a key pair
    let keyPairRes = membershipKeyGen(rln)
    require:
      keypairRes.isOk()
    
    let keyPair = keyPairRes.get()
    var pkBuffer = toBuffer(keyPair.idCommitment)
    let pkBufferPtr = addr pkBuffer

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

  test "insertMember rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()
    # generate a key pair
    let keyPairRes = rln.membershipKeyGen()
    require:
      keypairRes.isOk()
    check:
      rln.insertMember(keyPairRes.get().idCommitment)

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
    var
      root1 {.noinit.}: Buffer = Buffer()
      rootPtr1 = addr(root1)
      getRootSuccessful1 = getRoot(rln, rootPtr1)
    require:
      getRootSuccessful1
      root1.len == 32

    # generate a key pair
    let keyPairRes = membershipKeyGen(rln)
    require:
      keypairRes.isOk()
    
    let keyPair = keyPairRes.get()
    var pkBuffer = toBuffer(keyPair.idCommitment)
    let pkBufferPtr = addr pkBuffer

    # add the member to the tree
    let memberAdded = updateNextMember(rln, pkBufferPtr)
    require:
      memberAdded

    # read the Merkle Tree root after insertion
    var
      root2 {.noinit.}: Buffer = Buffer()
      rootPtr2 = addr(root2)
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
    var
      root3 {.noinit.}: Buffer = Buffer()
      rootPtr3 = addr(root3)
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

    # generate a key pair
    let keyPairRes = rln.membershipKeyGen()
    require:
      keyPairRes.isOk()
    let memberInserted = rln.insertMember(keypairRes.get().idCommitment)
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
    var
      msg = "Hello".toBytes()
      hashInput = appendLength(msg)
      hashInputBuffer = toBuffer(hashInput)

    # prepare other inputs to the hash function
    var outputBuffer: Buffer

    let hashSuccess = hash(rlnInstance.get(), addr hashInputBuffer,
        addr outputBuffer)
    check:
      hashSuccess
    let outputArr = cast[ptr array[32, byte]](outputBuffer.`ptr`)[]
  
    check:
      "1e32b3ab545c07c8b4a7ab1ca4f46bc31e4fdc29ac3b240ef1d54b4017a26e4c" ==
        outputArr.inHex()

    var
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

  test "check correctness of toMembershipKeyPairs and calcMerkleRoot":
    let groupKeys = StaticGroupKeys

    # create a set of MembershipKeyPair objects from groupKeys
    let groupKeyPairsRes = groupKeys.toMembershipKeyPairs()
    require:
      groupKeyPairsRes.isOk()
    
    let groupKeyPairs = groupKeyPairsRes.get()
    # extract the id commitments
    let groupIDCommitments = groupKeyPairs.mapIt(it.idCommitment)
    # calculate the Merkle tree root out of the extracted id commitments
    let rootRes = calcMerkleRoot(groupIDCommitments)

    require:
      rootRes.isOk()

    let root = rootRes.get()

    debug "groupKeyPairs", groupKeyPairs
    debug "groupIDCommitments", groupIDCommitments
    debug "root", root

    check:
      # check that the correct number of key pairs is created
      groupKeyPairs.len == StaticGroupSize
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

    check:
      decodednsp.isErr() == false
      decodednsp.value == rateLimitProof

  test "test proofVerify and proofGen for a valid proof":
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let
      # peer's index in the Merkle Tree
      index = 5
      # create a membership key pair
      memKeysRes = membershipKeyGen(rln)

    require:
      memKeysRes.isOk()
    
    let memKeys = memKeysRes.get()

    # Create a Merkle tree with random members
    for i in 0..10:
      var memberAdded: bool = false
      if (i == index):
        # insert the current peer's pk
        memberAdded = rln.insertMember(memKeys.idCommitment)
      else:
        # create a new key pair
        let memberKeysRes = rln.membershipKeyGen()
        require:
          memberKeysRes.isOk()
        memberAdded = rln.insertMember(memberKeysRes.get().idCommitment)
      # check the member is added
      require:
        memberAdded

    # prepare the message
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    var epoch: Epoch
    debug "epoch", epochHex = epoch.inHex()

    # generate proof
    let proofRes = rln.proofGen(data = messageBytes,
                                memKeys = memKeys,
                                memIndex = MembershipIndex(index),
                                epoch = epoch)
    check:
      proofRes.isOk()
    let proof = proofRes.value

    # verify the proof
    let verified = rln.proofVerify(data = messageBytes,
                                    proof = proof)

    # Ensure the proof verification did not error out

    check:
      verified.isOk()
      verified.value() == true

  test "test proofVerify and proofGen for an invalid proof":
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let
      # peer's index in the Merkle Tree
      index = 5
      # create a membership key pair
      memKeysRes = membershipKeyGen(rln)

    require:
      memKeysRes.isOk()

    let memKeys = memKeysRes.get()

    # Create a Merkle tree with random members
    for i in 0..10:
      var memberAdded: bool = false
      if (i == index):
        # insert the current peer's pk
        memberAdded = rln.insertMember(memKeys.idCommitment)
      else:
        # create a new key pair
        let memberKeysRes = rln.membershipKeyGen()
        require:
          memberKeysRes.isOk()
        memberAdded = rln.insertMember(memberKeysRes.get().idCommitment)
      # check the member is added
      require:
        memberAdded

    # prepare the message
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    var epoch: Epoch
    debug "epoch in bytes", epochHex = epoch.inHex()


    let badIndex = 4
    # generate proof
    let proofRes = rln.proofGen(data = messageBytes,
                                memKeys = memKeys,
                                memIndex = MembershipIndex(badIndex),
                                epoch = epoch)
    check:
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
      index = 5
      # create a membership key pair
      memKeysRes = membershipKeyGen(rlnRelay.rlnInstance)

    require:
      memKeysRes.isOk()
    
    let memKeys = memKeysRes.get()

    let membershipCount = AcceptableRootWindowSize + 5

    # Create a Merkle tree with random members
    for i in 0..membershipCount:
      var memberIsAdded: RlnRelayResult[void]
      if (i == index):
        # insert the current peer's pk
        memberIsAdded = rlnRelay.insertMember(memKeys.idCommitment)
      else:
        # create a new key pair
        let memberKeysRes = rlnRelay.rlnInstance.membershipKeyGen()
        require:
          memberKeysRes.isOk()
        memberIsAdded = rlnRelay.insertMember(memberKeysRes.get().idCommitment)
      # require that the member is added
      require:
        memberIsAdded.isOk()

    # Given: 
    # This step includes constructing a valid message with the latest merkle root
    # prepare the message
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    var epoch: Epoch
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = rlnRelay.rlnInstance.proofGen(data = messageBytes,
                                    memKeys = memKeys,
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
      discard rlnRelay.removeMember(MembershipIndex(i))
      # Ensure the local tree root has changed
      let currentMerkleRoot = rlnRelay.rlnInstance.getMerkleRoot()

      require:
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
      index = 6
      # create a membership key pair
      memKeysRes = membershipKeyGen(rlnRelay.rlnInstance)

    require:
      memKeysRes.isOk()

    let memKeys = memKeysRes.get()

    let membershipCount = AcceptableRootWindowSize + 5 

    # Create a Merkle tree with random members
    for i in 0..membershipCount:
      var memberIsAdded: RlnRelayResult[void]
      if (i == index):
        # insert the current peer's pk
        memberIsAdded = rlnRelay.insertMember(memKeys.idCommitment)
      else:
        # create a new key pair
        let memberKeysRes = rlnRelay.rlnInstance.membershipKeyGen()
        require:
          memberKeysRes.isOk()
        memberIsAdded = rlnRelay.insertMember(memberKeysRes.get().idCommitment)
      # require that the member is added
      require:
        memberIsAdded.isOk()

    # Given: 
    # This step includes constructing a valid message with the latest merkle root
    # prepare the message
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    var epoch: Epoch
    debug "epoch in bytes", epochHex = epoch.inHex()

    # generate proof
    let validProofRes = rlnRelay.rlnInstance.proofGen(data = messageBytes,
                                    memKeys = memKeys,
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

    #  cretae some dummy nullifiers and secret shares
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

    ## TODO: when zerokit rln is integrated, RateLimitProof should be initialized passing a rlnIdentifier too (now implicitely set to 0)
    let
      wm1 = WakuMessage(proof: RateLimitProof(epoch: epoch,
          nullifier: nullifier1, shareX: shareX1, shareY: shareY1))
      wm2 = WakuMessage(proof: RateLimitProof(epoch: epoch,
          nullifier: nullifier2, shareX: shareX2, shareY: shareY2))
      wm3 = WakuMessage(proof: RateLimitProof(epoch: epoch,
          nullifier: nullifier3, shareX: shareX3, shareY: shareY3))

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
    check:
      result3.isOk()
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
      # convert the keys to MembershipKeyPair structs
      groupKeyPairsRes = groupKeys.toMembershipKeyPairs()

    require:
      groupKeyPairsRes.isOk()

    let groupKeyPairs = groupKeyPairsRes.get()
    # extract the id commitments
    let groupIDCommitments = groupKeyPairs.mapIt(it.idCommitment)
    debug "groupKeyPairs", groupKeyPairs
    debug "groupIDCommitments", groupIDCommitments

    # index indicates the position of a membership key pair in the static list of group keys i.e., groupKeyPairs
    # the corresponding key pair will be used to mount rlnRelay on the current node
    # index also represents the index of the leaf in the Merkle tree that contains node's commitment key
    let index = MembershipIndex(5)

    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let
      wakuRlnRelay = WakuRLNRelay(membershipIndex: index,
          membershipKeyPair: groupKeyPairs[index], rlnInstance: rln)

    # add members
    let commitmentAddRes =  wakuRlnRelay.addAll(groupIDCommitments)
    require:
      commitmentAddRes.isOk()

    # get the current epoch time
    let time = epochTime()

    #  create some messages from the same peer and append rln proof to them, except wm4
    var
      wm1 = WakuMessage(payload: "Valid message".toBytes())
      proofAdded1 = wakuRlnRelay.appendRLNProof(wm1, time)
      # another message in the same epoch as wm1, it will break the messaging rate limit
      wm2 = WakuMessage(payload: "Spam".toBytes())
      proofAdded2 = wakuRlnRelay.appendRLNProof(wm2, time)
      #  wm3 points to the next epoch
      wm3 = WakuMessage(payload: "Valid message".toBytes())
      proofAdded3 = wakuRlnRelay.appendRLNProof(wm3, time+EpochUnitSeconds)
      wm4 = WakuMessage(payload: "Invalid message".toBytes())

    # checks proofs are added
    check:
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
    
    # create a key pair
    let keyPairRes = rln.membershipKeyGen()
    require:
      keyPairRes.isOk()

    let keyPair = keyPairRes.get()

    # convert the idCommitment to UInt256
    let idCUInt = keypair.idCommitment.toUInt256()
    # convert the UInt256 back to ICommitment
    let idCommitment = toIDCommitment(idCUInt)

    # check that the conversion has not distorted the original value
    check:
      keypair.idCommitment == idCommitment

  test "Read/Write RLN credentials":
    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()

    let keyPairRes = membershipKeyGen(rlnInstance.get())
    require:
      keyPairRes.isOk()

    let keyPair = keyPairRes.get()
    var empty: array[32, byte]
    check:
      keyPair.idKey.len == 32
      keyPair.idCommitment.len == 32
      keyPair.idKey != empty
      keyPair.idCommitment != empty

    debug "the generated membership key pair: ", keyPair

    let index =  MembershipIndex(1)

    let rlnMembershipCredentials = RlnMembershipCredentials(membershipKeyPair: keyPair, 
                                                            rlnIndex: index)

    let password = "%m0um0ucoW%"

    let filepath = "./testRLNCredentials.txt"
    defer: removeFile(filepath)

    # Write RLN credentials
    require:
      writeRlnCredentials(filepath, rlnMembershipCredentials, password).isOk()

    let readCredentialsResult = readRlnCredentials(filepath, password)
    check:
      readCredentialsResult.isOk()

    let credentials = readCredentialsResult.get()

    check:
      credentials.isSome()
      credentials.get().membershipKeyPair == keyPair
      credentials.get().rlnIndex == index

  test "histogram static bucket generation":
    let buckets = generateBucketsForHistogram(10)

    check:
      buckets.len == 5
      buckets == [2.0, 4.0, 6.0, 8.0, 10.0]
