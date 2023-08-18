import
  std/json
import
  chronicles,
  options,
  stew/[arrayops, results],
  nimcrypto/utils

import
  ./rln_interface,
  ../conversion_utils,
  ../protocol_types,
  ../protocol_metrics
import
  ../../waku_core,
  ../../waku_keystore

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
  if(done == false):
    return err("error in key generation")

  var generatedKeys = cast[ptr array[4*32, byte]](keysBufferPtr.`ptr`)[]
  # the public and secret keys together are 64 bytes
  if (generatedKeys.len != 4*32):
    return err("generated keys are of invalid length")

  # TODO define a separate proc to decode the generated keys to the secret and public components
  var
    idTrapdoor: array[32, byte]
    idNullifier: array[32, byte]
    idSecretHash: array[32, byte]
    idCommitment: array[32, byte]
  for (i, x) in idTrapdoor.mpairs: x = generatedKeys[i+0*32]
  for (i, x) in idNullifier.mpairs: x = generatedKeys[i+1*32]
  for (i, x) in idSecretHash.mpairs: x = generatedKeys[i+2*32]
  for (i, x) in idCommitment.mpairs: x = generatedKeys[i+3*32]

  var
    identityCredential = IdentityCredential(idTrapdoor: @idTrapdoor, idNullifier: @idNullifier, idSecretHash: @idSecretHash, idCommitment: @idCommitment)

  return ok(identityCredential)

type RlnTreeConfig = ref object of RootObj
  cache_capacity: int
  mode: string
  compression: bool
  flush_interval: int
  path: string

type RlnConfig = ref object of RootObj
  resources_folder: string
  tree_config: RlnTreeConfig

proc `%`(c: RlnConfig): JsonNode =
  ## wrapper around the generic JObject constructor.
  ## We don't need to have a separate proc for the tree_config field
  let tree_config = %{ "cache_capacity": %c.tree_config.cache_capacity,
                       "mode": %c.tree_config.mode,
                       "compression": %c.tree_config.compression,
                       "flush_interval": %c.tree_config.flush_interval,
                       "path": %c.tree_config.path }
  return %[("resources_folder", %c.resources_folder),
           ("tree_config", %tree_config)]

proc createRLNInstanceLocal(d = MerkleTreeDepth, 
                             tree_path = DefaultRlnTreePath): RLNResult =
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
      flush_interval: 500,
      path: if tree_path != "": tree_path else: DefaultRlnTreePath
    )
  )

  var serialized_rln_config = $(%rln_config)

  var
    rlnInstance: ptr RLN
    merkleDepth: csize_t = uint(d)
    configBuffer = serialized_rln_config.toOpenArrayByte(0, serialized_rln_config.high).toBuffer()

  # create an instance of RLN
  let res = new_circuit(merkleDepth, addr configBuffer, addr rlnInstance)
  # check whether the circuit parameters are generated successfully
  if (res == false):
    debug "error in parameters generation"
    return err("error in parameters generation")
  return ok(rlnInstance)

proc createRLNInstance*(d = MerkleTreeDepth, 
                        tree_path = DefaultRlnTreePath): RLNResult =
  ## Wraps the rln instance creation for metrics
  ## Returns an error if the instance creation fails
  var res: RLNResult
  waku_rln_instance_creation_duration_seconds.nanosecondTime:
    res = createRLNInstanceLocal(d, tree_path)
  return res

proc sha256*(data: openArray[byte]): RlnRelayResult[MerkleNode] =
  ## a thin layer on top of the Nim wrapper of the sha256 hasher
  trace "sha256 hash input", hashhex = data.toHex()
  var lenPrefData = encodeLengthPrefix(data)
  var
    hashInputBuffer = lenPrefData.toBuffer()
    outputBuffer: Buffer # will holds the hash output

  trace "sha256 hash input buffer length", bufflen = hashInputBuffer.len
  let
    hashSuccess = sha256(addr hashInputBuffer, addr outputBuffer)

  # check whether the hash call is done successfully
  if not hashSuccess:
    return err("error in sha256 hash")

  let
    output = cast[ptr MerkleNode](outputBuffer.`ptr`)[]

  return ok(output)

proc poseidon*(data: seq[seq[byte]]): RlnRelayResult[array[32, byte]] =
  ## a thin layer on top of the Nim wrapper of the poseidon hasher
  var inputBytes = serialize(data)
  var
    hashInputBuffer = inputBytes.toBuffer()
    outputBuffer: Buffer # will holds the hash output

  let
    hashSuccess = poseidon(addr hashInputBuffer, addr outputBuffer)

  # check whether the hash call is done successfully
  if not hashSuccess:
    return err("error in poseidon hash")

  let
    output = cast[ptr array[32, byte]](outputBuffer.`ptr`)[]

  return ok(output)

# TODO: collocate this proc with the definition of the RateLimitProof
# and the ProofMetadata types
proc extractMetadata*(proof: RateLimitProof): RlnRelayResult[ProofMetadata] =
  let externalNullifierRes = poseidon(@[@(proof.epoch),
                                        @(proof.rlnIdentifier)])
  if externalNullifierRes.isErr():
    return err("could not construct the external nullifier")
  return ok(ProofMetadata(
    nullifier: proof.nullifier,
    shareX: proof.shareX,
    shareY: proof.shareY,
    externalNullifier: externalNullifierRes.get()
  ))

proc proofGen*(rlnInstance: ptr RLN, data: openArray[byte],
    memKeys: IdentityCredential, memIndex: MembershipIndex,
    epoch: Epoch): RateLimitProofResult =

  # serialize inputs
  let serializedInputs = serialize(idSecretHash = memKeys.idSecretHash,
                                  memIndex = memIndex,
                                  epoch = epoch,
                                  msg = data)
  var inputBuffer = toBuffer(serializedInputs)

  debug "input buffer ", inputBuffer= repr(inputBuffer)

  # generate the proof
  var proof: Buffer
  let proofIsSuccessful = generate_proof(rlnInstance, addr inputBuffer, addr proof)
  # check whether the generate_proof call is done successfully
  if not proofIsSuccessful:
    return err("could not generate the proof")

  var proofValue = cast[ptr array[320, byte]] (proof.`ptr`)
  let proofBytes: array[320, byte] = proofValue[]
  debug "proof content", proofHex = proofValue[].toHex

  ## parse the proof as [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> ]

  let
    proofOffset = 128
    rootOffset = proofOffset + 32
    epochOffset = rootOffset + 32
    shareXOffset = epochOffset + 32
    shareYOffset = shareXOffset + 32
    nullifierOffset = shareYOffset + 32
    rlnIdentifierOffset = nullifierOffset + 32

  var
    zkproof: ZKSNARK
    proofRoot, shareX, shareY: MerkleNode
    epoch: Epoch
    nullifier: Nullifier
    rlnIdentifier: RlnIdentifier

  discard zkproof.copyFrom(proofBytes[0..proofOffset-1])
  discard proofRoot.copyFrom(proofBytes[proofOffset..rootOffset-1])
  discard epoch.copyFrom(proofBytes[rootOffset..epochOffset-1])
  discard shareX.copyFrom(proofBytes[epochOffset..shareXOffset-1])
  discard shareY.copyFrom(proofBytes[shareXOffset..shareYOffset-1])
  discard nullifier.copyFrom(proofBytes[shareYOffset..nullifierOffset-1])
  discard rlnIdentifier.copyFrom(proofBytes[nullifierOffset..rlnIdentifierOffset-1])

  let output = RateLimitProof(proof: zkproof,
                              merkleRoot: proofRoot,
                              epoch: epoch,
                              shareX: shareX,
                              shareY: shareY,
                              nullifier: nullifier,
                              rlnIdentifier: rlnIdentifier)

  return ok(output)

# validRoots should contain a sequence of roots in the acceptable windows.
# As default, it is set to an empty sequence of roots. This implies that the validity check for the proof's root is skipped
proc proofVerify*(rlnInstance: ptr RLN,
                  data: openArray[byte],
                  proof: RateLimitProof,
                  validRoots: seq[MerkleNode] = @[]): RlnRelayResult[bool] =
  ## verifies the proof, returns an error if the proof verification fails
  ## returns true if the proof is valid
  var
    proofBytes = serialize(proof, data)
    proofBuffer = proofBytes.toBuffer()
    validProof: bool
    rootsBytes = serialize(validRoots)
    rootsBuffer = rootsBytes.toBuffer()

  trace "serialized proof", proof = proofBytes.toHex()

  let verifyIsSuccessful = verify_with_roots(rlnInstance, addr proofBuffer, addr rootsBuffer, addr validProof)
  if not verifyIsSuccessful:
    # something went wrong in verification call
    warn "could not verify validity of the proof", proof=proof
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

proc getMember*(rlnInstance: ptr RLN, index: MembershipIndex): RlnRelayResult[IDCommitment] =
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

proc atomicWrite*(rlnInstance: ptr RLN, 
                  index = none(MembershipIndex), 
                  idComms = newSeq[IDCommitment](),
                  toRemoveIndices = newSeq[MembershipIndex]()): bool =
  ## Insert multiple members i.e., identity commitments, and remove multiple members
  ## returns true if the operation is successful
  ## returns false if the operation fails

  let startIndex = if index.isNone(): MembershipIndex(0) else: index.get()

  # serialize the idComms
  let idCommsBytes = serialize(idComms)
  var idCommsBuffer = idCommsBytes.toBuffer()
  let idCommsBufferPtr = addr idCommsBuffer

  # serialize the toRemoveIndices
  let indicesBytes = serialize(toRemoveIndices)
  var indicesBuffer = indicesBytes.toBuffer()
  let indicesBufferPtr = addr indicesBuffer

  let operationSuccess = atomic_write(rlnInstance, 
                                      startIndex, 
                                      idCommsBufferPtr, 
                                      indicesBufferPtr)
  return operationSuccess

proc insertMembers*(rlnInstance: ptr RLN,
                    index: MembershipIndex,
                    idComms: seq[IDCommitment]): bool =
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

  var rootValue = cast[ptr MerkleNode] (root.`ptr`)[]
  return ok(rootValue)

type
  RlnMetadata* = object
    lastProcessedBlock*: uint64

proc serialize(metadata: RlnMetadata): seq[byte] =
  ## serializes the metadata
  ## returns the serialized metadata
  return @(metadata.lastProcessedBlock.toBytes())

proc setMetadata*(rlnInstance: ptr RLN, metadata: RlnMetadata): RlnRelayResult[void] =
  ## sets the metadata of the RLN instance
  ## returns an error if the metadata could not be set
  ## returns void if the metadata is set successfully

  # serialize the metadata
  let metadataBytes = serialize(metadata)
  var metadataBuffer = metadataBytes.toBuffer()
  let metadataBufferPtr = addr metadataBuffer

  # set the metadata
  let metadataSet = set_metadata(rlnInstance, metadataBufferPtr)
  if not metadataSet:
    return err("could not set the metadata")
  return ok()

proc getMetadata*(rlnInstance: ptr RLN): RlnRelayResult[RlnMetadata] =
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
  if not metadata.len == 8:
    return err("wrong output size")

  var metadataValue = cast[ptr uint64] (metadata.`ptr`)[]
  return ok(RlnMetadata(lastProcessedBlock: metadataValue))
