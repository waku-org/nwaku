import std/json
import
  chronicles,
  options,
  eth/keys,
  stew/[arrayops, byteutils, endians2],
  stint,
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

proc createRLNInstanceLocal(d = MerkleTreeDepth): RLNResult =
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
    res = createRLNInstanceLocal(d)
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

type RlnMetadata* = object
  lastProcessedBlock*: uint64
  chainId*: UInt256
  contractAddress*: string
  validRoots*: seq[MerkleNode]

proc serialize(metadata: RlnMetadata): seq[byte] =
  ## serializes the metadata
  ## returns the serialized metadata
  return concat(
    @(metadata.lastProcessedBlock.toBytes()),
    @(metadata.chainId.toBytes(Endianness.littleEndian)[0 .. 7]),
    @(hexToSeqByte(toLower(metadata.contractAddress))),
    @(uint64(metadata.validRoots.len()).toBytes()),
    @(serialize(metadata.validRoots)),
  )

type MerkleNodeSeq = seq[MerkleNode]

proc deserialize(T: type MerkleNodeSeq, merkleNodeByteSeq: seq[byte]): T =
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
    chainId: UInt256
    contractAddress: string
    validRoots: MerkleNodeSeq

  # 8 + 8 + 20 + 8 + (5*32) = 204
  var metadataBytes = cast[ptr array[204, byte]](metadata.`ptr`)[]
  trace "received metadata bytes",
    metadataBytes = metadataBytes, len = metadataBytes.len

  lastProcessedBlock =
    uint64.fromBytes(metadataBytes[lastProcessedBlockOffset .. chainIdOffset - 1])
  chainId = UInt256.fromBytes(
    metadataBytes[chainIdOffset .. contractAddressOffset - 1], Endianness.littleEndian
  )
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
