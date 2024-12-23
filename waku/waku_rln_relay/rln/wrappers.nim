import std/json
import
  chronicles,
  options,
  eth/keys,
  stew/[arrayops, byteutils, endians2],
  results,
  std/[sequtils, strutils, tables]

import ./rln_interface, ../conversion_utils, ../protocol_types, ../protocol_metrics
import ../../waku_core, ../../waku_keystore

logScope:
  topics = "waku rln_relay ffi"

proc membershipKeyGen*(ctxPtr: ptr RLN): RlnRelayResult[IdentityCredential] =
  ## generates a IdentityCredential that can be used for the registration into the rln membership contract
  ## Returns an error if the key generation fails

  # keysBufferPtr will hold the generated identity tuple i.e., trapdoor, nullifier, secret hash and commitment
  var
    keysBuffer: Buffer
    keysBufferPtr = addr(keysBuffer)
    done = key_gen(ctxPtr, keysBufferPtr)

  # check whether the keys are generated successfully
  if (done == false):
    return err("error in key generation")

  if (keysBuffer.len != 4 * 32):
    return err("keysBuffer is of invalid length")

  var generatedKeys = cast[ptr array[4 * 32, byte]](keysBufferPtr.`ptr`)[]
  # the public and secret keys together are 64 bytes

  # TODO define a separate proc to decode the generated keys to the secret and public components
  var
    idTrapdoor: array[32, byte]
    idNullifier: array[32, byte]
    idSecretHash: array[32, byte]
    idCommitment: array[32, byte]
  for (i, x) in idTrapdoor.mpairs:
    x = generatedKeys[i + 0 * 32]
  for (i, x) in idNullifier.mpairs:
    x = generatedKeys[i + 1 * 32]
  for (i, x) in idSecretHash.mpairs:
    x = generatedKeys[i + 2 * 32]
  for (i, x) in idCommitment.mpairs:
    x = generatedKeys[i + 3 * 32]

  var identityCredential = IdentityCredential(
    idTrapdoor: @idTrapdoor,
    idNullifier: @idNullifier,
    idSecretHash: @idSecretHash,
    idCommitment: @idCommitment,
  )

  return ok(identityCredential)

type RlnTreeConfig = ref object of RootObj
  cache_capacity: int
  mode: string
  compression: bool
  flush_every_ms: int
  path: string

type RlnConfig = ref object of RootObj
  resources_folder: string
  tree_config: RlnTreeConfig

proc `%`(c: RlnConfig): JsonNode =
  ## wrapper around the generic JObject constructor.
  ## We don't need to have a separate proc for the tree_config field
  let tree_config =
    %{
      "cache_capacity": %c.tree_config.cache_capacity,
      "mode": %c.tree_config.mode,
      "compression": %c.tree_config.compression,
      "flush_every_ms": %c.tree_config.flush_every_ms,
      "path": %c.tree_config.path,
    }
  return %[("resources_folder", %c.resources_folder), ("tree_config", %tree_config)]

proc createRLNInstanceLocal(
    d = MerkleTreeDepth, tree_path = DefaultRlnTreePath
): RLNResult =
  ## generates an instance of RLN
  ## An RLN instance supports both zkSNARKs logics and Merkle tree data structure and operations
  ## d indicates the depth of Merkle tree
  ## tree_path indicates the path of the Merkle tree 
  ## Returns an error if the instance creation fails

  let rln_config = RlnConfig(
    resources_folder: "tree_height_" & $d & "/",
    tree_config: RlnTreeConfig(
      cache_capacity: 15_000,
      mode: "high_throughput",
      compression: false,
      flush_every_ms: 500,
      path: if tree_path != "": tree_path else: DefaultRlnTreePath,
    ),
  )

  var serialized_rln_config = $(%rln_config)

  var
    rlnInstance: ptr RLN
    merkleDepth: csize_t = uint(d)
    configBuffer =
      serialized_rln_config.toOpenArrayByte(0, serialized_rln_config.high).toBuffer()

  # create an instance of RLN
  let res = new_circuit(merkleDepth, addr configBuffer, addr rlnInstance)
  # check whether the circuit parameters are generated successfully
  if (res == false):
    debug "error in parameters generation"
    return err("error in parameters generation")
  return ok(rlnInstance)

proc createRLNInstance*(
    d = MerkleTreeDepth, tree_path = DefaultRlnTreePath
): RLNResult =
  ## Wraps the rln instance creation for metrics
  ## Returns an error if the instance creation fails
  var res: RLNResult
  waku_rln_instance_creation_duration_seconds.nanosecondTime:
    res = createRLNInstanceLocal(d, tree_path)
  return res

proc sha256*(data: openArray[byte]): RlnRelayResult[MerkleNode] =
  ## a thin layer on top of the Nim wrapper of the sha256 hasher
  var lenPrefData = encodeLengthPrefix(data)
  var
    hashInputBuffer = lenPrefData.toBuffer()
    outputBuffer: Buffer # will holds the hash output

  trace "sha256 hash input buffer length", bufflen = hashInputBuffer.len
  let hashSuccess = sha256(addr hashInputBuffer, addr outputBuffer)

  # check whether the hash call is done successfully
  if not hashSuccess:
    return err("error in sha256 hash")

  let output = cast[ptr MerkleNode](outputBuffer.`ptr`)[]

  return ok(output)

proc poseidon*(data: seq[seq[byte]]): RlnRelayResult[array[32, byte]] =
  ## a thin layer on top of the Nim wrapper of the poseidon hasher
  var inputBytes = serialize(data)
  var
    hashInputBuffer = inputBytes.toBuffer()
    outputBuffer: Buffer # will holds the hash output

  let hashSuccess = poseidon(addr hashInputBuffer, addr outputBuffer)

  # check whether the hash call is done successfully
  if not hashSuccess:
    return err("error in poseidon hash")

  let output = cast[ptr array[32, byte]](outputBuffer.`ptr`)[]

  return ok(output)

proc toLeaf*(rateCommitment: RateCommitment): RlnRelayResult[seq[byte]] =
  let idCommitment = rateCommitment.idCommitment
  var userMessageLimit: array[32, byte]
  try:
    discard userMessageLimit.copyFrom(
      toBytes(rateCommitment.userMessageLimit, Endianness.littleEndian)
    )
  except CatchableError:
    return err(
      "could not convert the user message limit to bytes: " & getCurrentExceptionMsg()
    )
  let leaf = poseidon(@[@idCommitment, @userMessageLimit]).valueOr:
    return err("could not convert the rate commitment to a leaf")
  var retLeaf = newSeq[byte](leaf.len)
  for i in 0 ..< leaf.len:
    retLeaf[i] = leaf[i]
  return ok(retLeaf)

proc toLeaves*(rateCommitments: seq[RateCommitment]): RlnRelayResult[seq[seq[byte]]] =
  var leaves = newSeq[seq[byte]]()
  for rateCommitment in rateCommitments:
    let leaf = toLeaf(rateCommitment).valueOr:
      return err("could not convert the rate commitment to a leaf: " & $error)
    leaves.add(leaf)
  return ok(leaves)

proc extractMetadata*(proof: RateLimitProof): RlnRelayResult[ProofMetadata] =
  let externalNullifier = poseidon(@[@(proof.epoch), @(proof.rlnIdentifier)]).valueOr:
    return err("could not construct the external nullifier")
  return ok(
    ProofMetadata(
      nullifier: proof.nullifier,
      shareX: proof.shareX,
      shareY: proof.shareY,
      externalNullifier: externalNullifier,
    )
  )

proc proofGen*(
    rlnInstance: ptr RLN,
    data: openArray[byte],
    membership: IdentityCredential,
    userMessageLimit: UserMessageLimit,
    messageId: MessageId,
    index: MembershipIndex,
    epoch: Epoch,
    rlnIdentifier = DefaultRlnIdentifier,
): RateLimitProofResult =
  # obtain the external nullifier
  let externalNullifierRes = poseidon(@[@(epoch), @(rlnIdentifier)])

  if externalNullifierRes.isErr():
    return err("could not construct the external nullifier")

  # serialize inputs
  let serializedInputs = serialize(
    idSecretHash = membership.idSecretHash,
    memIndex = index,
    userMessageLimit = userMessageLimit,
    messageId = messageId,
    externalNullifier = externalNullifierRes.get(),
    msg = data,
  )
  var inputBuffer = toBuffer(serializedInputs)

  # debug "input buffer ", inputBuffer = repr(inputBuffer)

  # generate the proof
  var proof: Buffer
  let proofIsSuccessful = generate_proof(rlnInstance, addr inputBuffer, addr proof)
  # check whether the generate_proof call is done successfully
  if not proofIsSuccessful:
    return err("could not generate the proof")

  var proofValue = cast[ptr array[320, byte]](proof.`ptr`)
  let proofBytes: array[320, byte] = proofValue[]
  debug "proof content", proofHex = proofValue[].toHex

  ## parse the proof as [ proof<128> | root<32> | external_nullifier<32> | share_x<32> | share_y<32> | nullifier<32> ]

  let
    proofOffset = 128
    rootOffset = proofOffset + 32
    externalNullifierOffset = rootOffset + 32
    shareXOffset = externalNullifierOffset + 32
    shareYOffset = shareXOffset + 32
    nullifierOffset = shareYOffset + 32

  var
    zkproof: ZKSNARK
    proofRoot, shareX, shareY: MerkleNode
    externalNullifier: ExternalNullifier
    nullifier: Nullifier

  discard zkproof.copyFrom(proofBytes[0 .. proofOffset - 1])
  discard proofRoot.copyFrom(proofBytes[proofOffset .. rootOffset - 1])
  discard
    externalNullifier.copyFrom(proofBytes[rootOffset .. externalNullifierOffset - 1])
  discard shareX.copyFrom(proofBytes[externalNullifierOffset .. shareXOffset - 1])
  discard shareY.copyFrom(proofBytes[shareXOffset .. shareYOffset - 1])
  discard nullifier.copyFrom(proofBytes[shareYOffset .. nullifierOffset - 1])

  let output = RateLimitProof(
    proof: zkproof,
    merkleRoot: proofRoot,
    externalNullifier: externalNullifier,
    epoch: epoch,
    rlnIdentifier: rlnIdentifier,
    shareX: shareX,
    shareY: shareY,
    nullifier: nullifier,
  )
  return ok(output)

# validRoots should contain a sequence of roots in the acceptable windows.
# As default, it is set to an empty sequence of roots. This implies that the validity check for the proof's root is skipped
proc proofVerify*(
    rlnInstance: ptr RLN,
    data: openArray[byte],
    proof: RateLimitProof,
    validRoots: seq[MerkleNode] = @[],
): RlnRelayResult[bool] =
  ## verifies the proof, returns an error if the proof verification fails
  ## returns true if the proof is valid
  var normalizedProof = proof
  # when we do this, we ensure that we compute the proof for the derived value
  # of the externalNullifier. The proof verification will fail if a malicious peer
  # attaches invalid epoch+rlnidentifier pair
  normalizedProof.externalNullifier = poseidon(
    @[@(proof.epoch), @(proof.rlnIdentifier)]
  ).valueOr:
    return err("could not construct the external nullifier")
  var
    proofBytes = serialize(normalizedProof, data)
    proofBuffer = proofBytes.toBuffer()
    validProof: bool
    rootsBytes = serialize(validRoots)
    rootsBuffer = rootsBytes.toBuffer()

  trace "serialized proof", proof = byteutils.toHex(proofBytes)

  let verifyIsSuccessful =
    verify_with_roots(rlnInstance, addr proofBuffer, addr rootsBuffer, addr validProof)
  if not verifyIsSuccessful:
    # something went wrong in verification call
    warn "could not verify validity of the proof", proof = proof
    return err("could not verify the proof")

  if not validProof:
    return ok(false)
  else:
    return ok(true)

proc insertMember*(rlnInstance: ptr RLN, idComm: IDCommitment): bool =
  ## inserts a member to the tree
  ## returns true if the member is inserted successfully
  ## returns false if the member could not be inserted
  var pkBuffer = toBuffer(idComm)
  let pkBufferPtr = addr pkBuffer

  # add the member to the tree
  let memberAdded = update_next_member(rlnInstance, pkBufferPtr)
  return memberAdded

proc getMember*(
    rlnInstance: ptr RLN, index: MembershipIndex
): RlnRelayResult[IDCommitment] =
  ## returns the member at the given index
  ## returns an error if the index is out of bounds
  ## returns the member if the index is valid
  var
    idCommitment {.noinit.}: Buffer = Buffer()
    idCommitmentPtr = addr(idCommitment)
    memberRetrieved = get_leaf(rlnInstance, index, idCommitmentPtr)

  if not memberRetrieved:
    return err("could not get the member")

  if not idCommitment.len == 32:
    return err("wrong output size")

  let idCommitmentValue = (cast[ptr array[32, byte]](idCommitment.`ptr`))[]

  return ok(@idCommitmentValue)

proc atomicWrite*(
    rlnInstance: ptr RLN,
    index = none(MembershipIndex),
    idComms = newSeq[IDCommitment](),
    toRemoveIndices = newSeq[MembershipIndex](),
): bool =
  ## Insert multiple members i.e., identity commitments, and remove multiple members
  ## returns true if the operation is successful
  ## returns false if the operation fails

  let startIndex =
    if index.isNone():
      MembershipIndex(0)
    else:
      index.get()

  # serialize the idComms
  let idCommsBytes = serialize(idComms)
  var idCommsBuffer = idCommsBytes.toBuffer()
  let idCommsBufferPtr = addr idCommsBuffer

  # serialize the toRemoveIndices
  let indicesBytes = serialize(toRemoveIndices)
  var indicesBuffer = indicesBytes.toBuffer()
  let indicesBufferPtr = addr indicesBuffer

  let operationSuccess =
    atomic_write(rlnInstance, startIndex, idCommsBufferPtr, indicesBufferPtr)
  return operationSuccess

proc insertMembers*(
    rlnInstance: ptr RLN, index: MembershipIndex, idComms: seq[IDCommitment]
): bool =
  ## Insert multiple members i.e., identity commitments
  ## returns true if the insertion is successful
  ## returns false if any of the insertions fails
  ## Note: This proc is atomic, i.e., if any of the insertions fails, all the previous insertions are rolled back

  return atomicWrite(rlnInstance, some(index), idComms)

proc removeMember*(rlnInstance: ptr RLN, index: MembershipIndex): bool =
  let deletionSuccess = delete_member(rlnInstance, index)
  return deletionSuccess

proc removeMembers*(rlnInstance: ptr RLN, indices: seq[MembershipIndex]): bool =
  return atomicWrite(rlnInstance, idComms = @[], toRemoveIndices = indices)

proc getMerkleRoot*(rlnInstance: ptr RLN): MerkleNodeResult =
  # read the Merkle Tree root after insertion
  var
    root {.noinit.}: Buffer = Buffer()
    rootPtr = addr(root)
    getRootSuccessful = getRoot(rlnInstance, rootPtr)
  if not getRootSuccessful:
    return err("could not get the root")
  if not root.len == 32:
    return err("wrong output size")

  var rootValue = cast[ptr MerkleNode](root.`ptr`)[]
  return ok(rootValue)

type RlnMetadata* = object
  lastProcessedBlock*: uint64
  chainId*: uint64
  contractAddress*: string
  validRoots*: seq[MerkleNode]

proc serialize(metadata: RlnMetadata): seq[byte] =
  ## serializes the metadata
  ## returns the serialized metadata
  return concat(
    @(metadata.lastProcessedBlock.toBytes()),
    @(metadata.chainId.toBytes()),
    @(hexToSeqByte(toLower(metadata.contractAddress))),
    @(uint64(metadata.validRoots.len()).toBytes()),
    @(serialize(metadata.validRoots)),
  )

type MerkleNodeSeq = seq[MerkleNode]

proc deserialize*(T: type MerkleNodeSeq, merkleNodeByteSeq: seq[byte]): T =
  ## deserializes a byte seq to a seq of MerkleNodes
  ## the order of serialization is |merkle_node_len<8>|merkle_node[len]|

  var roots = newSeq[MerkleNode]()
  let len = uint64.fromBytes(merkleNodeByteSeq[0 .. 7], Endianness.littleEndian)
  trace "length of valid roots", len
  for i in 0'u64 ..< len:
    # convert seq[byte] to array[32, byte]
    let fromByte = 8 + i * 32
    let toByte = fromByte + 31
    let rawRoot = merkleNodeByteSeq[fromByte .. toByte]
    trace "raw root", rawRoot = rawRoot
    var root: MerkleNode
    discard root.copyFrom(rawRoot)
    roots.add(root)
  return roots

proc setMetadata*(rlnInstance: ptr RLN, metadata: RlnMetadata): RlnRelayResult[void] =
  ## sets the metadata of the RLN instance
  ## returns an error if the metadata could not be set
  ## returns void if the metadata is set successfully

  # serialize the metadata
  let metadataBytes = serialize(metadata)
  trace "setting metadata",
    metadata = metadata, metadataBytes = metadataBytes, len = metadataBytes.len
  var metadataBuffer = metadataBytes.toBuffer()
  let metadataBufferPtr = addr metadataBuffer

  # set the metadata
  let metadataSet = set_metadata(rlnInstance, metadataBufferPtr)

  if not metadataSet:
    return err("could not set the metadata")
  return ok()

proc getMetadata*(rlnInstance: ptr RLN): RlnRelayResult[Option[RlnMetadata]] =
  ## gets the metadata of the RLN instance
  ## returns an error if the metadata could not be retrieved
  ## returns the metadata if the metadata is retrieved successfully

  # read the metadata
  var
    metadata {.noinit.}: Buffer = Buffer()
    metadataPtr = addr(metadata)
    getMetadataSuccessful = get_metadata(rlnInstance, metadataPtr)
  if not getMetadataSuccessful:
    return err("could not get the metadata")
  trace "metadata length", metadataLen = metadata.len

  if metadata.len == 0:
    return ok(none(RlnMetadata))

  let
    lastProcessedBlockOffset = 0
    chainIdOffset = lastProcessedBlockOffset + 8
    contractAddressOffset = chainIdOffset + 8
    validRootsOffset = contractAddressOffset + 20

  var
    lastProcessedBlock: uint64
    chainId: uint64
    contractAddress: string
    validRoots: MerkleNodeSeq

  # 8 + 8 + 20 + 8 + (5*32) = 204
  var metadataBytes = cast[ptr array[204, byte]](metadata.`ptr`)[]
  trace "received metadata bytes",
    metadataBytes = metadataBytes, len = metadataBytes.len

  lastProcessedBlock =
    uint64.fromBytes(metadataBytes[lastProcessedBlockOffset .. chainIdOffset - 1])
  chainId = uint64.fromBytes(metadataBytes[chainIdOffset .. contractAddressOffset - 1])
  contractAddress =
    byteutils.toHex(metadataBytes[contractAddressOffset .. validRootsOffset - 1])
  let validRootsBytes = metadataBytes[validRootsOffset .. metadataBytes.high]
  validRoots = MerkleNodeSeq.deserialize(validRootsBytes)

  return ok(
    some(
      RlnMetadata(
        lastProcessedBlock: lastProcessedBlock,
        chainId: chainId,
        contractAddress: "0x" & contractAddress,
        validRoots: validRoots,
      )
    )
  )
