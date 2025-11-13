## Code Migration Examples: Old FFI → New FFI2
## This file shows side-by-side comparisons of actual code migration

######################################################################
## Example 1: Key Generation
######################################################################

# OLD FFI (Buffer-based)
proc membershipKeyGen_OLD*(): RlnRelayResult[IdentityCredential] =
  var
    keysBuffer: Buffer
    keysBufferPtr = addr(keysBuffer)
    done = key_gen(keysBufferPtr, true)

  if (done == false):
    return err("error in key generation")

  if (keysBuffer.len != 4 * 32):
    return err("keysBuffer is of invalid length")

  var generatedKeys = cast[ptr array[4 * 32, byte]](keysBufferPtr.`ptr`)[]

  var
    idTrapdoor: array[32, byte]
    idNullifier: array[32, byte]
    idSecretHash: array[32, byte]
    idCommitment: array[32, byte]
  
  # Manual byte copying - error prone!
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

# NEW FFI2 (Struct-based)
proc membershipKeyGen_NEW*(): RlnRelayResult[IdentityCredential] =
  var credential: FFI2_IdentityCredential
  
  let success = ffi2_key_gen(addr credential)
  
  if not success:
    return err("error in key generation")

  # Serialize CFr fields to bytes
  var 
    idTrapdoorVec: Vec[uint8]
    idNullifierVec: Vec[uint8]
    idSecretHashVec: Vec[uint8]
    idCommitmentVec: Vec[uint8]
  
  discard ffi2_cfr_serialize(addr credential.identity_trapdoor, addr idTrapdoorVec)
  discard ffi2_cfr_serialize(addr credential.identity_nullifier, addr idNullifierVec)
  discard ffi2_cfr_serialize(addr credential.identity_secret_hash, addr idSecretHashVec)
  discard ffi2_cfr_serialize(addr credential.id_commitment, addr idCommitmentVec)

  let identityCredential = IdentityCredential(
    idTrapdoor: toSeq(idTrapdoorVec),
    idNullifier: toSeq(idNullifierVec),
    idSecretHash: toSeq(idSecretHashVec),
    idCommitment: toSeq(idCommitmentVec),
  )

  # Clean up
  freeVec(idTrapdoorVec)
  freeVec(idNullifierVec)
  freeVec(idSecretHashVec)
  freeVec(idCommitmentVec)

  return ok(identityCredential)

# COMPARISON:
# - OLD: 45 lines, manual byte manipulation, error-prone
# - NEW: 30 lines, type-safe, clearer intent
# - NEW: No manual offset calculation
# - NEW: Compiler catches type errors

######################################################################
## Example 2: RLN Instance Creation
######################################################################

# OLD FFI (Buffer-based config)
proc createRLNInstance_OLD(): RLNResult =
  let rln_config = RlnConfig(
    resources_folder: "tree_height_/",
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
    merkleDepth: csize_t = uint(20)
    configBuffer =
      serialized_rln_config.toOpenArrayByte(0, serialized_rln_config.high).toBuffer()

  # Pass serialized JSON as buffer
  let res = new_circuit(merkleDepth, addr configBuffer, addr rlnInstance)
  
  if (res == false):
    return err("error in parameters generation")
  return ok(rlnInstance)

# NEW FFI2 (File path config)
proc createRLNInstance_NEW(): RLNResult =
  let rln_config = RlnConfig(
    resources_folder: "tree_height_/",
    tree_config: RlnTreeConfig(
      cache_capacity: 15_000,
      mode: "high_throughput",
      compression: false,
      flush_every_ms: 500,
    ),
  )

  # Write config to file
  let config_json = $(%rln_config)
  let config_path = "/tmp/rln_config.json"
  writeFile(config_path, config_json)

  var rlnInstance: ptr RLN
  
  # Pass config file path (cleaner!)
  let res = ffi2_new(cstring(config_path), addr rlnInstance)
  
  if not res:
    return err("error in RLN instance creation")
  return ok(rlnInstance)

# COMPARISON:
# - OLD: Config passed as serialized buffer
# - NEW: Config passed as file path
# - NEW: Clearer separation of concerns
# - NEW: Easier to debug (can inspect config file)

######################################################################
## Example 3: SHA256 Hashing
######################################################################

# OLD FFI (Buffer manipulation)
proc sha256_OLD(data: openArray[byte]): RlnRelayResult[MerkleNode] =
  var lenPrefData = encodeLengthPrefix(data)
  var
    hashInputBuffer = lenPrefData.toBuffer()
    outputBuffer: Buffer

  let hashSuccess = sha256(addr hashInputBuffer, addr outputBuffer, true)

  if not hashSuccess:
    return err("error in sha256 hash")

  # Manual cast and dereference
  let output = cast[ptr MerkleNode](outputBuffer.`ptr`)[]

  return ok(output)

# NEW FFI2 (Typed operations)
proc sha256_NEW(data: openArray[byte]): RlnRelayResult[MerkleNode] =
  var lenPrefData = encodeLengthPrefix(data)
  var inputVec = newVec(lenPrefData)
  var outputCFr: CFr

  let hashSuccess = ffi2_hash_to_field_le(addr inputVec, addr outputCFr)
  
  if not hashSuccess:
    freeVec(inputVec)
    return err("error in sha256 hash")

  # Serialize to bytes
  var outputVec: Vec[uint8]
  discard ffi2_cfr_serialize(addr outputCFr, addr outputVec)

  var output: MerkleNode
  copyMem(addr output[0], outputVec.data, 32)

  freeVec(inputVec)
  freeVec(outputVec)

  return ok(output)

# COMPARISON:
# - OLD: Unsafe cast, no type checking
# - NEW: Type-safe CFr, explicit serialization
# - NEW: Memory management more explicit
# - NEW: Clearer what's happening

######################################################################
## Example 4: Proof Generation (Conceptual)
######################################################################

# OLD FFI (Manual serialization)
proc generateProof_OLD(
  ctx: ptr RLN,
  identitySecret: seq[byte],
  identityIndex: uint64,
  userMessageLimit: uint64,
  messageId: uint64,
  externalNullifier: seq[byte],
  signal: seq[byte]
): RlnRelayResult[ProofData] =
  
  # Manual buffer construction - VERY error prone!
  var inputBuffer: seq[byte]
  inputBuffer.add(identitySecret)                    # 32 bytes
  inputBuffer.add(toBytes(identityIndex))            # 8 bytes
  inputBuffer.add(toBytes(userMessageLimit))         # 32 bytes
  inputBuffer.add(toBytes(messageId))                # 32 bytes
  inputBuffer.add(externalNullifier)                 # 32 bytes
  inputBuffer.add(toBytes(uint64(signal.len)))       # 8 bytes
  inputBuffer.add(signal)                            # variable

  var input = inputBuffer.toBuffer()
  var output: Buffer

  let success = generate_proof(ctx, addr input, addr output)

  if not success:
    return err("proof generation failed")

  # Manual parsing - VERY error prone!
  let proof = output.ptr[0..127]
  let root = output.ptr[128..159]
  let extNull = output.ptr[160..191]
  let shareX = output.ptr[192..223]
  let shareY = output.ptr[224..255]
  let nullifier = output.ptr[256..287]

  return ok(ProofData(
    proof: proof,
    root: root,
    externalNullifier: extNull,
    shareX: shareX,
    shareY: shareY,
    nullifier: nullifier
  ))

# NEW FFI2 (Structured approach)
proc generateProof_NEW(
  ctx: ptr RLN,
  identitySecret: seq[byte],
  userMessageLimit: uint64,
  messageId: uint64,
  merkleProof: seq[seq[byte]],
  merkleIndices: seq[byte],
  externalNullifier: seq[byte],
  signal: seq[byte]
): RlnRelayResult[FFI2_RLNProof] =
  
  # Convert to CFr types (type-safe!)
  var identitySecretCFr: CFr
  var identitySecretVec = newVec(identitySecret)
  discard ffi2_hash_to_field_le(addr identitySecretVec, addr identitySecretCFr)
  freeVec(identitySecretVec)

  var userMessageLimitCFr: CFr
  discard ffi2_cfr_from_uint(userMessageLimit, addr userMessageLimitCFr)

  var messageIdCFr: CFr
  discard ffi2_cfr_from_uint(messageId, addr messageIdCFr)

  # Convert merkle proof
  var pathElementsCFr: seq[CFr]
  for element in merkleProof:
    var elementVec = newVec(element)
    var cfr: CFr
    discard ffi2_hash_to_field_le(addr elementVec, addr cfr)
    pathElementsCFr.add(cfr)
    freeVec(elementVec)

  var externalNullifierCFr: CFr
  var externalNullifierVec = newVec(externalNullifier)
  discard ffi2_hash_to_field_le(addr externalNullifierVec, addr externalNullifierCFr)
  freeVec(externalNullifierVec)

  var xCFr: CFr
  discard ffi2_cfr_zero(addr xCFr)

  # Build witness struct (type-safe!)
  var witness = FFI2_RLNWitnessInput(
    identity_secret: identitySecretCFr,
    user_message_limit: userMessageLimitCFr,
    message_id: messageIdCFr,
    path_elements: newVec(pathElementsCFr),
    identity_path_index: newVec(merkleIndices),
    x: xCFr,
    external_nullifier: externalNullifierCFr
  )

  var signalVec = newVec(signal)
  var proof: FFI2_RLNProof

  # Single function call with structured types
  let success = ffi2_generate_rln_proof(
    ctx,
    addr witness,
    addr signalVec,
    addr proof
  )

  # Clean up
  freeVec(witness.path_elements)
  freeVec(witness.identity_path_index)
  freeVec(signalVec)

  if not success:
    return err("proof generation failed")

  # Proof is already structured - no parsing needed!
  return ok(proof)

# COMPARISON:
# - OLD: Manual byte packing (error-prone offsets)
# - NEW: Structured witness input (type-safe)
# - OLD: Manual output parsing (error-prone offsets)
# - NEW: Structured proof output (direct field access)
# - OLD: Easy to make offset errors
# - NEW: Compiler catches type mismatches
# - OLD: Hard to debug (hex dumps)
# - NEW: Easy to debug (named fields)

######################################################################
## Example 5: Proof Verification
######################################################################

# OLD FFI (Buffer-based)
proc verifyProof_OLD(
  ctx: ptr RLN,
  proof: seq[byte],
  root: seq[byte],
  externalNullifier: seq[byte],
  shareX: seq[byte],
  shareY: seq[byte],
  nullifier: seq[byte],
  signal: seq[byte]
): RlnRelayResult[bool] =
  
  # Manual buffer construction
  var proofBuffer: seq[byte]
  proofBuffer.add(proof)                        # 128 bytes
  proofBuffer.add(root)                         # 32 bytes
  proofBuffer.add(externalNullifier)            # 32 bytes
  proofBuffer.add(shareX)                       # 32 bytes
  proofBuffer.add(shareY)                       # 32 bytes
  proofBuffer.add(nullifier)                    # 32 bytes
  proofBuffer.add(toBytes(uint64(signal.len)))  # 8 bytes
  proofBuffer.add(signal)                       # variable

  var buffer = proofBuffer.toBuffer()
  var isValid: bool

  let success = verify(ctx, addr buffer, addr isValid)

  if not success:
    return err("verification failed")

  return ok(isValid)

# NEW FFI2 (Structured)
proc verifyProof_NEW(
  ctx: ptr RLN,
  proof: FFI2_RLNProof,  # Already structured!
  signal: seq[byte]
): RlnRelayResult[bool] =
  
  var signalVec = newVec(signal)
  var rootsVec: Vec[CFr]  # Empty = use context root
  var isValid: bool

  # Single function call with structured proof
  let success = ffi2_verify_rln_proof(
    ctx,
    unsafeAddr proof,
    addr signalVec,
    addr rootsVec,
    addr isValid
  )

  freeVec(signalVec)

  if not success:
    return err("verification failed")

  return ok(isValid)

# COMPARISON:
# - OLD: Manual buffer construction from separate fields
# - NEW: Proof is already a struct
# - OLD: Signal embedded in proof buffer
# - NEW: Signal separate parameter (cleaner)
# - OLD: More code, more error-prone
# - NEW: Less code, type-safe

######################################################################
## Key Takeaways
######################################################################

# 1. TYPE SAFETY
#    - OLD: Everything is bytes, no compile-time checks
#    - NEW: Typed structs, compiler catches errors

# 2. MEMORY MANAGEMENT
#    - OLD: Implicit, easy to leak or corrupt
#    - NEW: Explicit with Vec helpers, clearer ownership

# 3. CODE CLARITY
#    - OLD: Manual offsets, hard to understand
#    - NEW: Named fields, self-documenting

# 4. ERROR SURFACE
#    - OLD: Many places to make offset errors
#    - NEW: Fewer error opportunities

# 5. DEBUGGING
#    - OLD: Hex dumps, manual calculation
#    - NEW: Named fields, IDE support

# 6. MAINTENANCE
#    - OLD: Change requires updating all offsets
#    - NEW: Change struct definition, compiler helps

# 7. PERFORMANCE
#    - OLD: Multiple memory copies (serialize/deserialize)
#    - NEW: Direct struct access (zero-copy when possible)

######################################################################
## Migration Strategy
######################################################################

# Step 1: Create parallel FFI2 implementations
#   - Keep old code working
#   - Add new FFI2 versions alongside
#   - Test thoroughly

# Step 2: Migrate one module at a time
#   - Start with simple functions (key generation)
#   - Move to complex functions (proof generation)
#   - Keep tests passing

# Step 3: Update call sites
#   - Replace old function calls with new ones
#   - Update data structures if needed
#   - Verify behavior unchanged

# Step 4: Remove old code
#   - Once all migrations complete
#   - Remove old FFI interface
#   - Clean up unused code

# Step 5: Optimize
#   - Look for unnecessary conversions
#   - Reduce memory allocations
#   - Benchmark performance
