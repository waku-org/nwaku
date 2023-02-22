import
  chronicles,
  options,
  stew/[arrayops, results],
  nimcrypto/utils

import
  ./rln_interface,
  ../conversion_utils,
  ../protocol_types,
  ../protocol_metrics,
  ../constants
import
  ../../waku_keystore,
  ../../../utils/time

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

proc createRLNInstanceLocal*(d: int = MerkleTreeDepth): RLNResult =
  ## generates an instance of RLN
  ## An RLN instance supports both zkSNARKs logics and Merkle tree data structure and operations
  ## d indicates the depth of Merkle tree
  ## Returns an error if the instance creation fails
  var
    rlnInstance: ptr RLN
    merkleDepth: csize_t = uint(d)
    resourcesPathBuffer = RlnResourceFolder.toOpenArrayByte(0, RlnResourceFolder.high).toBuffer()

  # create an instance of RLN
  let res = new_circuit(merkleDepth, addr resourcesPathBuffer, addr rlnInstance)
  # check whether the circuit parameters are generated successfully
  if (res == false):
    debug "error in parameters generation"
    return err("error in parameters generation")
  return ok(rlnInstance)

proc createRLNInstance*(d: int = MerkleTreeDepth): RLNResult =
  ## Wraps the rln instance creation for metrics
  ## Returns an error if the instance creation fails
  var res: RLNResult
  waku_rln_instance_creation_duration_seconds.nanosecondTime:
    res = createRLNInstanceLocal(d)
  return res

proc sha256*(data: openArray[byte]): MerkleNode =
  ## a thin layer on top of the Nim wrapper of the sha256 hasher
  debug "sha256 hash input", hashhex = data.toHex()
  var lenPrefData = appendLength(data)
  var
    hashInputBuffer = lenPrefData.toBuffer()
    outputBuffer: Buffer # will holds the hash output

  debug "sha256 hash input buffer length", bufflen = hashInputBuffer.len
  let
    hashSuccess = sha256(addr hashInputBuffer, addr outputBuffer)

  # check whether the hash call is done successfully
  if not hashSuccess:
    debug "error in sha256 hash"
    return default(MerkleNode)

  let
    output = cast[ptr MerkleNode](outputBuffer.`ptr`)[]

  return output

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


proc insertMembers*(rlnInstance: ptr RLN,
                      index: MembershipIndex,
                      idComms: seq[IDCommitment]): bool =
    ## Insert multiple members i.e., identity commitments
    ## returns true if the insertion is successful
    ## returns false if any of the insertions fails
    ## Note: This proc is atomic, i.e., if any of the insertions fails, all the previous insertions are rolled back

    # serialize the idComms
    let idCommsBytes = serializeIdCommitments(idComms)

    var idCommsBuffer = idCommsBytes.toBuffer()
    let idCommsBufferPtr = addr idCommsBuffer
    # add the member to the tree
    let membersAdded = set_leaves_from(rlnInstance, index, idCommsBufferPtr)
    return membersAdded

proc removeMember*(rlnInstance: ptr RLN, index: MembershipIndex): bool =
  let deletion_success = delete_member(rlnInstance, index)
  return deletion_success

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
