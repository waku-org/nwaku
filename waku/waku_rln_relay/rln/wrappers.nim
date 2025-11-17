## Updated wrappers using FFI2 interface
## This file demonstrates the migration from buffer-based to struct-based FFI

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
  topics = "waku rln_relay ffi2"

######################################################################
## Identity Generation (Migrated to FFI2)
######################################################################

proc membershipKeyGen*(): RlnRelayResult[IdentityCredential] =
  ## Generates an IdentityCredential using the new FFI2 interface
  ## Much simpler than the old buffer-based approach!

  var credential: FFI2_IdentityCredential

  let success = ffi2_key_gen(addr credential)

  if not success:
    return err("error in key generation")

  # Serialize CFr fields to bytes for compatibility with existing code
  var
    idTrapdoorVec: Vec[uint8]
    idNullifierVec: Vec[uint8]
    idSecretHashVec: Vec[uint8]
    idCommitmentVec: Vec[uint8]

  if not ffi2_cfr_serialize(addr credential.identity_trapdoor, addr idTrapdoorVec):
    return err("failed to serialize identity trapdoor")
  if not ffi2_cfr_serialize(addr credential.identity_nullifier, addr idNullifierVec):
    return err("failed to serialize identity nullifier")
  if not ffi2_cfr_serialize(addr credential.identity_secret_hash, addr idSecretHashVec):
    return err("failed to serialize identity secret hash")
  if not ffi2_cfr_serialize(addr credential.id_commitment, addr idCommitmentVec):
    return err("failed to serialize id commitment")

  # Convert Vec to seq
  let identityCredential = IdentityCredential(
    idTrapdoor: toSeq(idTrapdoorVec),
    idNullifier: toSeq(idNullifierVec),
    idSecretHash: toSeq(idSecretHashVec),
    idCommitment: toSeq(idCommitmentVec),
  )

  # Clean up allocated memory
  freeVec(idTrapdoorVec)
  freeVec(idNullifierVec)
  freeVec(idSecretHashVec)
  freeVec(idCommitmentVec)

  return ok(identityCredential)

######################################################################
## RLN Instance Creation (Migrated to FFI2)
######################################################################

type RlnTreeConfig = ref object of RootObj
  cache_capacity: int
  mode: string
  compression: bool
  flush_every_ms: int

type RlnConfig = ref object of RootObj
  resources_folder: string
  tree_config: RlnTreeConfig

proc `%`(c: RlnConfig): JsonNode =
  ## Wrapper around the generic JObject constructor
  let tree_config =
    %{
      "cache_capacity": %c.tree_config.cache_capacity,
      "mode": %c.tree_config.mode,
      "compression": %c.tree_config.compression,
      "flush_every_ms": %c.tree_config.flush_every_ms,
    }
  return %[("resources_folder", %c.resources_folder), ("tree_config", %tree_config)]

proc createRLNInstanceLocal(): RLNResult =
  ## Generates an instance of RLN using FFI2
  ## Now uses config file path instead of serialized JSON buffer

  let rln_config = RlnConfig(
    resources_folder: "tree_height_/",
    tree_config: RlnTreeConfig(
      cache_capacity: 15_000,
      mode: "high_throughput",
      compression: false,
      flush_every_ms: 500,
    ),
  )

  # Write config to temporary file
  # In production, you might want to use a persistent config file
  let config_json = $(%rln_config)
  let config_path = "/tmp/rln_config.json"

  try:
    writeFile(config_path, config_json)
  except IOError:
    return err("failed to write RLN config file")

  var rlnInstance: ptr RLN

  # Create RLN instance using config file path (FFI2 way)
  let res = ffi2_new(cstring(config_path), addr rlnInstance)

  if not res:
    info "error in RLN instance creation"
    return err("error in RLN instance creation")

  return ok(rlnInstance)

proc createRLNInstance*(): RLNResult =
  ## Wraps the rln instance creation for metrics
  var res: RLNResult
  waku_rln_instance_creation_duration_seconds.nanosecondTime:
    res = createRLNInstanceLocal()
  return res

######################################################################
## Hashing Functions (Migrated to FFI2)
######################################################################

proc sha256*(data: openArray[byte]): RlnRelayResult[MerkleNode] =
  ## SHA256 hash using FFI2 interface
  ## Now uses hash_to_field_le instead of raw buffer manipulation

  var lenPrefData = encodeLengthPrefix(data)
  var inputVec = newVec(lenPrefData)
  var outputCFr: CFr

  trace "sha256 hash input buffer length", bufflen = inputVec.len

  let hashSuccess = ffi2_hash_to_field_le(addr inputVec, addr outputCFr)

  if not hashSuccess:
    freeVec(inputVec)
    return err("error in sha256 hash")

  # Serialize CFr to bytes
  var outputVec: Vec[uint8]
  if not ffi2_cfr_serialize(addr outputCFr, addr outputVec):
    freeVec(inputVec)
    return err("error serializing hash output")

  # Convert to MerkleNode (32 bytes)
  var output: MerkleNode
  if outputVec.len >= 32:
    copyMem(addr output[0], outputVec.data, 32)
  else:
    freeVec(inputVec)
    freeVec(outputVec)
    return err("hash output too short")

  freeVec(inputVec)
  freeVec(outputVec)

  return ok(output)

proc poseidon*(data: seq[seq[byte]]): RlnRelayResult[array[32, byte]] =
  ## Poseidon hash using FFI2 interface
  ## Now uses typed CFr elements instead of raw buffers

  # Convert input data to CFr elements
  var inputCFrs: seq[CFr]
  for item in data:
    var itemVec = newVec(item)
    var cfr: CFr

    if not ffi2_hash_to_field_le(addr itemVec, addr cfr):
      freeVec(itemVec)
      return err("error converting input to field element")

    inputCFrs.add(cfr)
    freeVec(itemVec)

  # Create Vec[CFr] for input
  var inputVec = newVec(inputCFrs)
  var outputCFr: CFr

  let hashSuccess = ffi2_poseidon_hash(addr inputVec, addr outputCFr)

  if not hashSuccess:
    freeVec(inputVec)
    return err("error in poseidon hash")

  # Serialize output to bytes
  var outputVec: Vec[uint8]
  if not ffi2_cfr_serialize(addr outputCFr, addr outputVec):
    freeVec(inputVec)
    return err("error serializing hash output")

  var output: array[32, byte]
  if outputVec.len >= 32:
    copyMem(addr output[0], outputVec.data, 32)
  else:
    freeVec(inputVec)
    freeVec(outputVec)
    return err("hash output too short")

  freeVec(inputVec)
  freeVec(outputVec)

  return ok(output)

######################################################################
## Rate Commitment Functions (Updated for FFI2)
######################################################################

proc toLeaf*(rateCommitment: RateCommitment): RlnRelayResult[seq[byte]] =
  ## Converts a rate commitment to a leaf using FFI2
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
  ## Converts multiple rate commitments to leaves
  var leaves = newSeq[seq[byte]]()
  for rateCommitment in rateCommitments:
    let leaf = toLeaf(rateCommitment).valueOr:
      return err("could not convert the rate commitment to a leaf: " & $error)
    leaves.add(leaf)
  return ok(leaves)

proc extractMetadata*(proof: RateLimitProof): RlnRelayResult[ProofMetadata] =
  ## Extracts metadata from a proof using FFI2
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

######################################################################
## Example: Proof Generation (NEW - shows how to use FFI2)
######################################################################

proc generateProof*(
    ctx: ptr RLN,
    identitySecret: seq[byte],
    userMessageLimit: uint64,
    messageId: uint64,
    merkleProof: seq[seq[byte]], # path elements
    merkleIndices: seq[byte],
    externalNullifier: seq[byte],
    signal: seq[byte],
): RlnRelayResult[FFI2_RLNProof] =
  ## Example of proof generation using FFI2
  ## This shows the new structured approach

  # Convert identity secret to CFr
  var identitySecretVec = newVec(identitySecret)
  var identitySecretCFr: CFr
  if not ffi2_hash_to_field_le(addr identitySecretVec, addr identitySecretCFr):
    freeVec(identitySecretVec)
    return err("failed to convert identity secret")
  freeVec(identitySecretVec)

  # Convert user message limit to CFr
  var userMessageLimitCFr: CFr
  if not ffi2_cfr_from_uint(userMessageLimit, addr userMessageLimitCFr):
    return err("failed to convert user message limit")

  # Convert message ID to CFr
  var messageIdCFr: CFr
  if not ffi2_cfr_from_uint(messageId, addr messageIdCFr):
    return err("failed to convert message ID")

  # Convert merkle proof path elements to CFr
  var pathElementsCFr: seq[CFr]
  for element in merkleProof:
    var elementVec = newVec(element)
    var cfr: CFr
    if not ffi2_hash_to_field_le(addr elementVec, addr cfr):
      freeVec(elementVec)
      return err("failed to convert path element")
    pathElementsCFr.add(cfr)
    freeVec(elementVec)

  # Convert external nullifier to CFr
  var externalNullifierVec = newVec(externalNullifier)
  var externalNullifierCFr: CFr
  if not ffi2_hash_to_field_le(addr externalNullifierVec, addr externalNullifierCFr):
    freeVec(externalNullifierVec)
    return err("failed to convert external nullifier")
  freeVec(externalNullifierVec)

  # Compute x (Shamir share x-coordinate) - simplified for example
  var xCFr: CFr
  if not ffi2_cfr_zero(addr xCFr):
    return err("failed to create x coordinate")

  # Build witness input struct
  var witness = FFI2_RLNWitnessInput(
    identity_secret: identitySecretCFr,
    user_message_limit: userMessageLimitCFr,
    message_id: messageIdCFr,
    path_elements: newVec(pathElementsCFr),
    identity_path_index: newVec(merkleIndices),
    x: xCFr,
    external_nullifier: externalNullifierCFr,
  )

  # Prepare signal
  var signalVec = newVec(signal)

  # Generate proof
  var proof: FFI2_RLNProof
  let success = ffi2_generate_rln_proof(ctx, addr witness, addr signalVec, addr proof)

  # Clean up
  freeVec(witness.path_elements)
  freeVec(witness.identity_path_index)
  freeVec(signalVec)

  if not success:
    return err("proof generation failed")

  return ok(proof)

######################################################################
## Example: Proof Verification (NEW - shows how to use FFI2)
######################################################################

proc verifyProof*(
    ctx: ptr RLN,
    proof: FFI2_RLNProof,
    signal: seq[byte],
    roots: seq[seq[byte]] = @[] # Optional multiple roots
    ,
): RlnRelayResult[bool] =
  ## Example of proof verification using FFI2

  var signalVec = newVec(signal)

  # Convert roots to CFr if provided
  var rootsCFr: seq[CFr]
  for root in roots:
    var rootVec = newVec(root)
    var cfr: CFr
    if not ffi2_hash_to_field_le(addr rootVec, addr cfr):
      freeVec(rootVec)
      freeVec(signalVec)
      return err("failed to convert root")
    rootsCFr.add(cfr)
    freeVec(rootVec)

  var rootsVec = newVec(rootsCFr)
  var isValid: bool

  let success = ffi2_verify_rln_proof(
    ctx, unsafeAddr proof, addr signalVec, addr rootsVec, addr isValid
  )

  freeVec(signalVec)
  freeVec(rootsVec)

  if not success:
    return err("proof verification call failed")

  return ok(isValid)
