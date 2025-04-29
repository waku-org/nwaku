## Nim wrappers for the functions defined in librln
import ../protocol_types

{.push raises: [].}

## Buffer struct is taken from
# https://github.com/celo-org/celo-threshold-bls-rs/blob/master/crates/threshold-bls-ffi/src/ffi.rs
type Buffer* = object
  `ptr`*: ptr uint8
  len*: uint

proc toBuffer*(x: openArray[byte]): Buffer =
  ## converts the input to a Buffer object
  ## the Buffer object is used to communicate data with the rln lib
  var temp = @x
  let baseAddr = cast[pointer](x)
  let output = Buffer(`ptr`: cast[ptr uint8](baseAddr), len: uint(temp.len))
  return output

######################################################################
## RLN Zerokit module APIs
######################################################################

#------------------------------ Merkle Tree operations -----------------------------------------
proc update_next_member*(
  ctx: ptr RLN, input_buffer: ptr Buffer
): bool {.importc: "set_next_leaf".}

## adds an element in the merkle tree to the next available position
## input_buffer points to the id commitment byte seq
## the return bool value indicates the success or failure of the operation

proc delete_member*(ctx: ptr RLN, index: uint): bool {.importc: "delete_leaf".}
## index is the position of the id commitment key to be deleted from the tree
## the deleted id commitment key is replaced with a zero leaf
## the return bool value indicates the success or failure of the operation

proc get_root*(ctx: ptr RLN, output_buffer: ptr Buffer): bool {.importc: "get_root".}
## get_root populates the passed pointer output_buffer with the current tree root
## the output_buffer holds the Merkle tree root of size 32 bytes
## the return bool value indicates the success or failure of the operation

proc get_merkle_proof*(
  ctx: ptr RLN, index: uint, output_buffer: ptr Buffer
): bool {.importc: "get_proof".}

## populates the passed pointer output_buffer with the merkle proof for the leaf at position index in the tree stored by ctx
## the output_buffer holds a serialized Merkle proof (vector of 32 bytes nodes)
## the return bool value indicates the success or failure of the operation

proc set_leaf*(
  ctx: ptr RLN, index: uint, input_buffer: ptr Buffer
): bool {.importc: "set_leaf".}

## sets the leaf at position index in the tree stored by ctx to the value passed by input_buffer
## the input_buffer holds a serialized leaf of 32 bytes
## the return bool value indicates the success or failure of the operation

proc get_leaf*(
  ctx: ptr RLN, index: uint, output_buffer: ptr Buffer
): bool {.importc: "get_leaf".}

## gets the leaf at position index in the tree stored by ctx
## the output_buffer holds a serialized leaf of 32 bytes
## the return bool value indicates the success or failure of the operation

proc leaves_set*(ctx: ptr RLN): uint {.importc: "leaves_set".}
## gets the number of leaves set in the tree stored by ctx
## the return uint value indicates the number of leaves set in the tree

proc init_tree_with_leaves*(
  ctx: ptr RLN, input_buffer: ptr Buffer
): bool {.importc: "init_tree_with_leaves".}

## sets multiple leaves in the tree stored by ctx to the value passed by input_buffer
## the input_buffer holds a serialized vector of leaves (32 bytes each)
## the input_buffer size is prefixed by a 8 bytes integer indicating the number of leaves
## leaves are set one after each other starting from index 0
## the return bool value indicates the success or failure of the operation

proc atomic_write*(
  ctx: ptr RLN, index: uint, leaves_buffer: ptr Buffer, indices_buffer: ptr Buffer
): bool {.importc: "atomic_operation".}

## sets multiple leaves, and zeroes out indices in the tree stored by ctx to the value passed by input_buffer
## the leaves_buffer holds a serialized vector of leaves (32 bytes each)
## the leaves_buffer size is prefixed by a 8 bytes integer indicating the number of leaves
## the indices_bufffer holds a serialized vector of indices (8 bytes each)
## the indices_buffer size is prefixed by a 8 bytes integer indicating the number of indices
## leaves are set one after each other starting from index `index`
## the return bool value indicates the success or failure of the operation

proc reset_tree*(ctx: ptr RLN, tree_height: uint): bool {.importc: "set_tree".}
## resets the tree stored by ctx to the empty tree (all leaves set to 0) of height tree_height
## the return bool value indicates the success or failure of the operation

#----------------------------------------------------------------------------------------------

#-------------------------------- zkSNARKs operations -----------------------------------------
proc key_gen*(
  ctx: ptr RLN, output_buffer: ptr Buffer
): bool {.importc: "extended_key_gen".}

## generates identity trapdoor, identity nullifier, identity secret hash and id commitment tuple serialized inside output_buffer as | identity_trapdoor<32> | identity_nullifier<32> | identity_secret_hash<32> | id_commitment<32> |
## identity secret hash is the poseidon hash of [identity_trapdoor, identity_nullifier]
## id commitment is the poseidon hash of the identity secret hash
## the return bool value indicates the success or failure of the operation

proc seeded_key_gen*(
  ctx: ptr RLN, input_buffer: ptr Buffer, output_buffer: ptr Buffer
): bool {.importc: "seeded_extended_key_gen".}

## generates identity trapdoor, identity nullifier, identity secret hash and id commitment tuple serialized inside output_buffer as | identity_trapdoor<32> | identity_nullifier<32> | identity_secret_hash<32> | id_commitment<32> | using ChaCha20
## seeded with an arbitrary long seed serialized in input_buffer
## The input seed provided by the user is hashed using Keccak256 before being passed to ChaCha20 as seed.
## identity secret hash is the poseidon hash of [identity_trapdoor, identity_nullifier]
## id commitment is the poseidon hash of the identity secret hash
## the return bool value indicates the success or failure of the operation

proc generate_proof*(
  ctx: ptr RLN, input_buffer: ptr Buffer, output_buffer: ptr Buffer
): bool {.importc: "generate_rln_proof".}

## rln-v2
## input_buffer has to be serialized as [ identity_secret<32> | identity_index<8> | user_message_limit<32> | message_id<32> | external_nullifier<32> | signal_len<8> | signal<var> ]
## output_buffer holds the proof data and should be parsed as [ proof<128> | root<32> | external_nullifier<32> | share_x<32> | share_y<32> | nullifier<32> ]
## rln-v1
## input_buffer has to be serialized as [ id_key<32> | id_index<8> | epoch<32> | signal_len<8> | signal<var> ]
## output_buffer holds the proof data and should be parsed as [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> ]
## integers wrapped in <> indicate value sizes in bytes
## the return bool value indicates the success or failure of the operation

proc generate_proof_with_witness*(
  ctx: ptr RLN, input_buffer: ptr Buffer, output_buffer: ptr Buffer
): bool {.importc: "generate_rln_proof_with_witness".}

## rln-v2
## witness term refer to collection of secret inputs with proper serialization
## input_buffer has to be serialized as [ identity_secret<32> | user_message_limit<32> | message_id<32> | path_elements<Vec<32>> | identity_path_index<Vec<1>> | x<32> | external_nullifier<32> ]
## output_buffer holds the proof data and should be parsed as [ proof<128> | root<32> | external_nullifier<32> | share_x<32> | share_y<32> | nullifier<32> ]
## rln-v1
## input_buffer has to be serialized as [ id_key<32> | path_elements<Vec<32>> | identity_path_index<Vec<1>> | x<32> | epoch<32> | rln_identifier<32> ]
## output_buffer holds the proof data and should be parsed as [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> ]
## integers wrapped in <> indicate value sizes in bytes
## path_elements and identity_path_index serialize a merkle proof and are vectors of elements of 32 and 1 bytes respectively
## the return bool value indicates the success or failure of the operation

proc verify*(
  ctx: ptr RLN, proof_buffer: ptr Buffer, proof_is_valid_ptr: ptr bool
): bool {.importc: "verify_rln_proof".}

## rln-v2
## proof_buffer has to be serialized as [ proof<128> | root<32> | external_nullifier<32> | share_x<32> | share_y<32> | nullifier<32> | signal_len<8> | signal<var> ]
## rln-v1
## ## proof_buffer has to be serialized as [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> | signal_len<8> | signal<var> ]
## the return bool value indicates the success or failure of the call to the verify function
## the verification of the zk proof is available in proof_is_valid_ptr, where a value of true indicates success and false a failure

proc verify_with_roots*(
  ctx: ptr RLN,
  proof_buffer: ptr Buffer,
  roots_buffer: ptr Buffer,
  proof_is_valid_ptr: ptr bool,
): bool {.importc: "verify_with_roots".}

## rln-v2
## proof_buffer has to be serialized as [ proof<128> | root<32> | external_nullifier<32> | share_x<32> | share_y<32> | nullifier<32> | signal_len<8> | signal<var> ]
## rln-v1
## proof_buffer has to be serialized as [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> | signal_len<8> | signal<var> ]
## roots_buffer contains the concatenation of 32 bytes long serializations in little endian of root values
## the return bool value indicates the success or failure of the call to the verify function
## the verification of the zk proof is available in proof_is_valid_ptr, where a value of true indicates success and false a failure

proc zk_prove*(
  ctx: ptr RLN, input_buffer: ptr Buffer, output_buffer: ptr Buffer
): bool {.importc: "prove".}

## Computes the zkSNARK proof and stores it in output_buffer for input values stored in input_buffer
## rln-v2
## input_buffer is serialized as input_data as [ identity_secret<32> | user_message_limit<32> | message_id<32> | path_elements<Vec<32>> | identity_path_index<Vec<1>> | x<32> | external_nullifier<32> ]
## rln-v1
## input_buffer is serialized as input_data as [ id_key<32> | path_elements<Vec<32>> | identity_path_index<Vec<1>> | x<32> | epoch<32> | rln_identifier<32> ]
## output_buffer holds the proof data and should be parsed as [ proof<128> ]
## path_elements and indentity_path elements serialize a merkle proof for id_key and are vectors of elements of 32 and 1 bytes, respectively (not. Vec<>).
## x is the x coordinate of the Shamir's secret share for which the proof is computed
## epoch is the input epoch (equivalently, the nullifier)
## the return bool value indicates the success or failure of the operation

proc zk_verify*(
  ctx: ptr RLN, proof_buffer: ptr Buffer, proof_is_valid_ptr: ptr bool
): bool {.importc: "verify".}

## Verifies the zkSNARK proof passed in proof_buffer
## input_buffer is serialized as input_data as [ proof<128> ]
## the verification of the zk proof is available in proof_is_valid_ptr, where a value of true indicates success and false a failure
## the return bool value indicates the success or failure of the operation

#----------------------------------------------------------------------------------------------

#-------------------------------- Common procedures -------------------------------------------
proc new_circuit*(
  tree_height: uint, input_buffer: ptr Buffer, ctx: ptr (ptr RLN)
): bool {.importc: "new".}

## creates an instance of rln object as defined by the zerokit RLN lib
## tree_height represent the depth of the Merkle tree
## input_buffer contains a serialization of the path where the circuit resources can be found (.r1cs, .wasm, .zkey and optionally the verification_key.json)
## ctx holds the final created rln object
## the return bool value indicates the success or failure of the operation

proc new_circuit_from_data*(
  tree_height: uint,
  circom_buffer: ptr Buffer,
  zkey_buffer: ptr Buffer,
  vk_buffer: ptr Buffer,
  ctx: ptr (ptr RLN),
): bool {.importc: "new_with_params".}

## creates an instance of rln object as defined by the zerokit RLN lib by passing the required inputs as byte arrays
## tree_height represent the depth of the Merkle tree
## circom_buffer contains the bytes read from the Circom .wasm circuit
## zkey_buffer contains the bytes read from the .zkey proving key
## vk_buffer contains the bytes read from the verification_key.json
## ctx holds the final created rln object
## the return bool value indicates the success or failure of the operation

#-------------------------------- Hashing utils -------------------------------------------

proc sha256*(
  input_buffer: ptr Buffer, output_buffer: ptr Buffer
): bool {.importc: "hash".}

## it hashes (sha256) the plain text supplied in inputs_buffer and then maps it to a field element
## this proc is used to map arbitrary signals to field element for the sake of proof generation
## inputs_buffer holds the hash input as a byte seq
## the hash output is generated and populated inside output_buffer
## the output_buffer contains 32 bytes hash output

proc poseidon*(
  input_buffer: ptr Buffer, output_buffer: ptr Buffer
): bool {.importc: "poseidon_hash".}

## it hashes (poseidon) the plain text supplied in inputs_buffer
## this proc is used to compute the identity secret hash, and external nullifier
## inputs_buffer holds the hash input as a byte seq
## the hash output is generated and populated inside output_buffer
## the output_buffer contains 32 bytes hash output

#-------------------------------- Persistent Metadata utils -------------------------------------------

proc set_metadata*(
  ctx: ptr RLN, input_buffer: ptr Buffer
): bool {.importc: "set_metadata".}

## sets the metadata stored by ctx to the value passed by input_buffer
## the input_buffer holds a serialized representation of the metadata (format to be defined)
## input_buffer holds the metadata as a byte seq
## the return bool value indicates the success or failure of the operation

proc get_metadata*(
  ctx: ptr RLN, output_buffer: ptr Buffer
): bool {.importc: "get_metadata".}

## gets the metadata stored by ctx and populates the passed pointer output_buffer with it
## the output_buffer holds the metadata as a byte seq
## the return bool value indicates the success or failure of the operation

proc flush*(ctx: ptr RLN): bool {.importc: "flush".}
## flushes the write buffer to the database
## the return bool value indicates the success or failure of the operation
## This allows more robust and graceful handling of the database connection
