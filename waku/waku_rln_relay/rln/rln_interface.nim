## Nim wrappers for the NEW FFI2 functions defined in librln
## This is the migrated version using structured types instead of raw buffers
import ../protocol_types

{.push raises: [].}

######################################################################
## FFI2 Type Definitions
######################################################################

## Field element type - represents elements in the finite field
type CFr* = object
  data: array[32, byte] # Internal representation

## Vector type for dynamic arrays
type Vec*[T] = object
  data*: ptr T
  len*: csize_t
  cap*: csize_t

## Identity credential structure
type FFI2_IdentityCredential* = object
  identity_trapdoor*: CFr
  identity_nullifier*: CFr
  identity_secret_hash*: CFr
  id_commitment*: CFr

## RLN Witness Input - all data needed for proof generation
type FFI2_RLNWitnessInput* = object
  identity_secret*: CFr
  user_message_limit*: CFr
  message_id*: CFr
  path_elements*: Vec[CFr] # Merkle proof path
  identity_path_index*: Vec[uint8] # Merkle proof indices
  x*: CFr # Shamir secret share x-coordinate
  external_nullifier*: CFr

## RLN Proof structure - output of proof generation
type FFI2_RLNProof* = object
  proof*: Vec[uint8] # 128 bytes zkSNARK proof
  root*: CFr # Merkle tree root
  external_nullifier*: CFr
  share_x*: CFr # Shamir secret share x
  share_y*: CFr # Shamir secret share y
  nullifier*: CFr # Message nullifier

## Merkle proof structure
type FFI2_MerkleProof* = object
  path_elements*: Vec[CFr]
  indices*: Vec[uint8]

######################################################################
## RLN Zerokit FFI2 APIs
######################################################################

#-------------------------------- Identity Generation -----------------------------------------

proc ffi2_key_gen*(
  output: ptr FFI2_IdentityCredential
): bool {.importc: "ffi2_key_gen".}

## Generates identity trapdoor, identity nullifier, identity secret hash and id commitment
## Output is written directly to the FFI2_IdentityCredential struct
## Returns true on success, false on failure

proc ffi2_seeded_key_gen*(
  seed: ptr Vec[uint8], output: ptr FFI2_IdentityCredential
): bool {.importc: "ffi2_seeded_key_gen".}

## Generates identity using a seed (hashed with Keccak256, then used with ChaCha20)
## Returns true on success, false on failure

#-------------------------------- Circuit/Context Initialization -----------------------------------------

proc ffi2_new*(config_path: cstring, ctx: ptr (ptr RLN)): bool {.importc: "ffi2_new".}
## Creates an RLN instance from a config file
## config_path: path to JSON config file containing tree settings and resources folder
## ctx: pointer to store the created RLN instance
## Returns true on success, false on failure

proc ffi2_new_with_params*(
  zkey: ptr Vec[uint8], graph: ptr Vec[uint8], ctx: ptr (ptr RLN)
): bool {.importc: "ffi2_new_with_params".}

## Creates an RLN instance from raw circuit parameters
## zkey: proving key data
## graph: circuit graph data
## ctx: pointer to store the created RLN instance
## Returns true on success, false on failure

#-------------------------------- Proof Generation -----------------------------------------

proc ffi2_generate_rln_proof*(
  ctx: ptr RLN,
  witness: ptr FFI2_RLNWitnessInput,
  signal: ptr Vec[uint8],
  output: ptr FFI2_RLNProof,
): bool {.importc: "ffi2_generate_rln_proof".}

## Generates an RLN proof using the Merkle tree in the context
## witness: structured witness input with all proof parameters
## signal: the message being proven
## output: structured proof output
## Returns true on success, false on failure

proc ffi2_generate_rln_proof_stateless*(
  zkey: ptr Vec[uint8],
  graph: ptr Vec[uint8],
  witness: ptr FFI2_RLNWitnessInput,
  signal: ptr Vec[uint8],
  output: ptr FFI2_RLNProof,
): bool {.importc: "ffi2_generate_rln_proof_stateless".}

## Generates an RLN proof without maintaining context state
## Useful for one-off proof generation
## Returns true on success, false on failure

#-------------------------------- Proof Verification -----------------------------------------

proc ffi2_verify_rln_proof*(
  ctx: ptr RLN,
  proof: ptr FFI2_RLNProof,
  signal: ptr Vec[uint8],
  roots: ptr Vec[CFr], # Can be empty to use root from context
  is_valid: ptr bool,
): bool {.importc: "ffi2_verify_rln_proof".}

## Verifies an RLN proof
## proof: structured proof to verify
## signal: the message that was proven
## roots: optional vector of valid roots (empty = use context root)
## is_valid: output parameter - true if proof is valid
## Returns true if verification completed, false on error
## Check is_valid for actual proof validity

#-------------------------------- Merkle Tree Operations -----------------------------------------

proc ffi2_set_leaf*(
  ctx: ptr RLN, index: csize_t, leaf: ptr CFr
): bool {.importc: "ffi2_set_leaf".}

## Sets a leaf at the specified index in the Merkle tree
## Returns true on success, false on failure

proc ffi2_get_leaf*(
  ctx: ptr RLN, index: csize_t, output: ptr CFr
): bool {.importc: "ffi2_get_leaf".}

## Gets the leaf at the specified index from the Merkle tree
## Returns true on success, false on failure

proc ffi2_get_root*(ctx: ptr RLN, output: ptr CFr): bool {.importc: "ffi2_get_root".}
## Gets the current Merkle tree root
## Returns true on success, false on failure

proc ffi2_get_proof*(
  ctx: ptr RLN, index: csize_t, output: ptr FFI2_MerkleProof
): bool {.importc: "ffi2_get_proof".}

## Gets the Merkle proof for the leaf at the specified index
## Returns true on success, false on failure

proc ffi2_verify_merkle_proof*(
  ctx: ptr RLN, leaf: ptr CFr, proof: ptr FFI2_MerkleProof, is_valid: ptr bool
): bool {.importc: "ffi2_verify_proof".}

## Verifies a Merkle proof
## is_valid: output parameter - true if proof is valid
## Returns true if verification completed, false on error

proc ffi2_set_leaves*(
  ctx: ptr RLN, start_index: csize_t, leaves: ptr Vec[CFr]
): bool {.importc: "ffi2_set_leaves".}

## Sets multiple leaves starting at start_index
## Returns true on success, false on failure

proc ffi2_set_leaves_from*(
  ctx: ptr RLN, start_index: csize_t, leaves: ptr Vec[CFr]
): bool {.importc: "ffi2_set_leaves_from".}

## Sets leaves from a specific index (alternative batch operation)
## Returns true on success, false on failure

#-------------------------------- Hashing Functions -----------------------------------------

proc ffi2_hash_to_field_le*(
  input: ptr Vec[uint8], output: ptr CFr
): bool {.importc: "ffi2_hash_to_field_le".}

## Hashes arbitrary bytes to a field element (little-endian)
## Used to map signals to field elements
## Returns true on success, false on failure

proc ffi2_hash_to_field_be*(
  input: ptr Vec[uint8], output: ptr CFr
): bool {.importc: "ffi2_hash_to_field_be".}

## Hashes arbitrary bytes to a field element (big-endian)
## Returns true on success, false on failure

proc ffi2_poseidon_hash*(
  inputs: ptr Vec[CFr], output: ptr CFr
): bool {.importc: "ffi2_poseidon_hash".}

## Computes Poseidon hash of field elements
## Used for identity secret hash and external nullifier
## Returns true on success, false on failure

#-------------------------------- Serialization Utilities -----------------------------------------

proc ffi2_cfr_serialize*(
  fr: ptr CFr, output: ptr Vec[uint8]
): bool {.importc: "ffi2_cfr_serialize".}

## Serializes a field element to bytes
## Returns true on success, false on failure

proc ffi2_cfr_deserialize*(
  bytes: ptr Vec[uint8], output: ptr CFr
): bool {.importc: "ffi2_cfr_deserialize".}

## Deserializes bytes to a field element
## Returns true on success, false on failure

proc ffi2_vec_cfr_serialize*(
  vec: ptr Vec[CFr], output: ptr Vec[uint8]
): bool {.importc: "ffi2_vec_cfr_serialize".}

## Serializes a vector of field elements to bytes
## Returns true on success, false on failure

proc ffi2_vec_cfr_deserialize*(
  bytes: ptr Vec[uint8], output: ptr Vec[CFr]
): bool {.importc: "ffi2_vec_cfr_deserialize".}

## Deserializes bytes to a vector of field elements
## Returns true on success, false on failure

proc ffi2_cfr_from_uint*(
  value: uint64, output: ptr CFr
): bool {.importc: "ffi2_cfr_from_uint".}

## Creates a field element from an unsigned integer
## Returns true on success, false on failure

proc ffi2_cfr_zero*(output: ptr CFr): bool {.importc: "ffi2_cfr_zero".}
## Creates a zero field element
## Returns true on success, false on failure

#-------------------------------- Helper Procedures -----------------------------------------

proc newVec*[T](data: seq[T]): Vec[T] =
  ## Helper to create a Vec from a Nim seq
  if data.len == 0:
    return Vec[T](data: nil, len: 0, cap: 0)

  var vecData = cast[ptr T](alloc(sizeof(T) * data.len))
  copyMem(vecData, unsafeAddr data[0], sizeof(T) * data.len)

  return Vec[T](data: vecData, len: csize_t(data.len), cap: csize_t(data.len))

proc toSeq*[T](vec: Vec[T]): seq[T] =
  ## Helper to convert a Vec to a Nim seq
  if vec.len == 0 or vec.data == nil:
    return @[]

  result = newSeq[T](vec.len)
  copyMem(addr result[0], vec.data, sizeof(T) * vec.len.int)

proc freeVec*[T](vec: var Vec[T]) =
  ## Helper to free a Vec's memory
  if vec.data != nil:
    dealloc(vec.data)
    vec.data = nil
    vec.len = 0
    vec.cap = 0
