# this module contains the Nim wrappers for the rln library https://github.com/kilic/rln/blob/3bbec368a4adc68cd5f9bfae80b17e1bbb4ef373/src/ffi.rs

{.push raises: [Defect].}

import
  os,
  waku_rln_relay_types

when defined(rln) or (not defined(rln) and not defined(rlnzerokit)):
  const libPath = "vendor/rln/target/debug/"
when defined(rlnzerokit):
  const libPath = "vendor/zerokit/target/release/"

when defined(Windows):
  const libName* = libPath / "rln.dll"
elif defined(Linux):
  const libName* = libPath / "librln.so"
elif defined(MacOsX):
  const libName* = libPath / "librln.dylib"

# all the following procedures are Nim wrappers for the functions defined in libName
{.push dynlib: libName, raises: [Defect].}


## Buffer struct is taken from
# https://github.com/celo-org/celo-threshold-bls-rs/blob/master/crates/threshold-bls-ffi/src/ffi.rs
type Buffer* = object
  `ptr`*: ptr uint8
  len*: uint

######################################################################
## Kilic's RLN module APIs
######################################################################

when defined(rln) or (not defined(rln) and not defined(rlnzerokit)):

  #------------------------------ Merkle Tree operations -----------------------------------------
  proc update_next_member*(ctx: RLN[Bn256],
                          input_buffer: ptr Buffer): bool {.importc: "update_next_member".}
  ## input_buffer points to the id commitment byte seq
  ## the return bool value indicates the success or failure of the operation

  proc delete_member*(ctx: RLN[Bn256], index: uint): bool {.importc: "delete_member".}
  ## index is the position of the id commitment key to be deleted from the tree
  ## the deleted id commitment key is replaced with a zero leaf
  ## the return bool value indicates the success or failure of the operation

  proc get_root*(ctx: RLN[Bn256], output_buffer: ptr Buffer): bool {.importc: "get_root".}
  ## get_root populates the passed pointer output_buffer with the current tree root
  ## the output_buffer holds the Merkle tree root of size 32 bytes
  ## the return bool value indicates the success or failure of the operation
  ## 
  #----------------------------------------------------------------------------------------------
  #-------------------------------- zkSNARKs operations -----------------------------------------
  proc key_gen*(ctx: RLN[Bn256], keypair_buffer: ptr Buffer): bool {.importc: "key_gen".}
  ## generates id key and id commitment key serialized inside keypair_buffer as | id_key <32 bytes>| id_commitment_key <32 bytes> |
  ## id commitment is the poseidon hash of the id key
  ## the return bool value indicates the success or failure of the operation

  proc generate_proof*(ctx: RLN[Bn256],
                      input_buffer: ptr Buffer,
                      output_buffer: ptr Buffer): bool {.importc: "generate_proof".}
  ## input_buffer serialized as  [ id_key<32> | id_index<8> | epoch<32> | signal_len<8> | signal<var> ]
  ## output_buffer holds the proof data and should be parsed as |proof<256>|root<32>|epoch<32>|share_x<32>|share_y<32>|nullifier<32>|
  ## integers wrapped in <> indicate value sizes in bytes
  ## the return bool value indicates the success or failure of the operation
  ## 
  proc verify*(ctx: RLN[Bn256],
              proof_buffer: ptr Buffer,
              result_ptr: ptr uint32): bool {.importc: "verify".}
  ## proof_buffer [ proof<256>| root<32>| epoch<32>| share_x<32>| share_y<32>| nullifier<32> | signal_len<8> | signal<var> ]
  ## the return bool value indicates the success or failure of the call to the verify function
  ## the result of the verification of the zk proof is stored in the value pointed by result_ptr, where 0 indicates success and 1 is failure


  #----------------------------------------------------------------------------------------------
  #-------------------------------- Common procedures -------------------------------------------

  proc new_circuit_from_params*(merkle_depth: uint,
                                parameters_buffer: ptr Buffer,
                                ctx: ptr RLN[Bn256]): bool {.importc: "new_circuit_from_params".}
  ## creates an instance of rln object as defined by the rln lib https://github.com/kilic/rln/blob/7ac74183f8b69b399e3bc96c1ae8ab61c026dc43/src/public.rs#L48
  ## merkle_depth represent the depth of the Merkle tree
  ## parameters_buffer holds prover and verifier keys
  ## ctx holds the final created rln object
  ## the return bool value indicates the success or failure of the operation


  proc hash*(ctx: RLN[Bn256],
            inputs_buffer: ptr Buffer,
            output_buffer: ptr Buffer): bool {.importc: "signal_to_field".}
  ## as explained in https://github.com/kilic/rln/blob/7ac74183f8b69b399e3bc96c1ae8ab61c026dc43/src/public.rs#L135, it hashes (sha256) the plain text supplied in inputs_buffer and then maps it to a field element
  ## this proc is used to map arbitrary signals to field element for the sake of proof generation
  ## inputs_buffer holds the hash input as a byte seq 
  ## the hash output is generated and populated inside output_buffer 
  ## the output_buffer contains 32 bytes hash output 


######################################################################
## RLN Zerokit module APIs
######################################################################

when defined(rlnzerokit):
  #------------------------------ Merkle Tree operations -----------------------------------------
  proc update_next_member*(ctx: ptr RLN, input_buffer: ptr Buffer): bool {.importc: "set_next_leaf".}
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

  proc get_merkle_proof*(ctx: ptr RLN, index: uint, output_buffer: ptr Buffer): bool {.importc: "get_proof".}
  ## populates the passed pointer output_buffer with the merkle proof for the leaf at position index in the tree stored by ctx
  ## the output_buffer holds a serialized Merkle proof (vector of 32 bytes nodes)
  ## the return bool value indicates the success or failure of the operation

  proc set_leaf*(ctx: ptr RLN, index: uint, input_buffer: ptr Buffer): bool {.importc: "set_leaf".}
  ## sets the leaf at position index in the tree stored by ctx to the value passed by input_buffer
  ## the input_buffer holds a serialized leaf of 32 bytes
  ## the return bool value indicates the success or failure of the operation

  proc set_leaves*(ctx: ptr RLN, input_buffer: ptr Buffer): bool {.importc: "set_leaves".}
  ## sets multiple leaves in the tree stored by ctx to the value passed by input_buffer
  ## the input_buffer holds a serialized vector of leaves (32 bytes each)
  ## leaves are set one after each other starting from index 0
  ## the return bool value indicates the success or failure of the operation

  proc reset_tree*(ctx: ptr RLN, tree_height: uint): bool {.importc: "set_tree".}
  ## resets the tree stored by ctx to the the empty tree (all leaves set to 0) of height tree_height
  ## the return bool value indicates the success or failure of the operation

  #----------------------------------------------------------------------------------------------

  #-------------------------------- zkSNARKs operations -----------------------------------------
  proc key_gen*(ctx: ptr RLN, output_buffer: ptr Buffer): bool {.importc: "key_gen".}
  ## generates id key and id commitment key serialized inside output_buffer as | id_key <32 bytes>| id_commitment_key <32 bytes> |
  ## id commitment is the poseidon hash of the id key
  ## the return bool value indicates the success or failure of the operation

  proc seeded_key_gen*(ctx: ptr RLN, input_buffer: ptr Buffer, output_buffer: ptr Buffer): bool {.importc: "seeded_key_gen".}
  ## generates id key and id commitment key serialized inside output_buffer as | id_key <32 bytes>| id_commitment_key <32 bytes> | using ChaCha20
  ## seeded with an arbitrary long seed serialized in input_buffer
  ## The input seed provided by the user is hashed using Keccak256 before being passed to ChaCha20 as seed.
  ## id commitment is the poseidon hash of the id key
  ## the return bool value indicates the success or failure of the operation

  proc generate_proof*(ctx: ptr RLN,
                           input_buffer: ptr Buffer,
                           output_buffer: ptr Buffer): bool {.importc: "generate_rln_proof".}
  ## input_buffer has to be serialized as [ id_key<32> | id_index<8> | epoch<32> | signal_len<8> | signal<var> ]
  ## output_buffer holds the proof data and should be parsed as [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> ]
  ## integers wrapped in <> indicate value sizes in bytes
  ## the return bool value indicates the success or failure of the operation
   
  proc verify*(ctx: ptr RLN,
                         proof_buffer: ptr Buffer,
                         proof_is_valid_ptr: ptr bool): bool {.importc: "verify_rln_proof".}
  ## proof_buffer has to be serialized as [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> | signal_len<8> | signal<var> ]
  ## the return bool value indicates the success or failure of the call to the verify function
  ## the verification of the zk proof is available in proof_is_valid_ptr, where a value of true indicates success and false a failure

  proc verify_with_roots*(ctx: ptr RLN,
                        proof_buffer: ptr Buffer,
                        roots_buffer: ptr Buffer,
                        proof_is_valid_ptr: ptr bool): bool {.importc: "verify_with_roots".}
  ## proof_buffer has to be serialized as [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> | signal_len<8> | signal<var> ]
  ## roots_buffer contains the concatenation of 32 bytes long serializations in little endian of root values 
  ## the return bool value indicates the success or failure of the call to the verify function
  ## the verification of the zk proof is available in proof_is_valid_ptr, where a value of true indicates success and false a failure

  proc zk_prove*(ctx: ptr RLN,
              input_buffer: ptr Buffer,
              output_buffer: ptr Buffer): bool {.importc: "prove".}
  ## Computes the zkSNARK proof and stores it in output_buffer for input values stored in input_buffer
  ## input_buffer is serialized as input_data as [ id_key<32> | path_elements<Vec<32>> | identity_path_index<Vec<1>> | x<32> | epoch<32> | rln_identifier<32> ]
  ## output_buffer holds the proof data and should be parsed as [ proof<128> ]
  ## path_elements and indentity_path elements serialize a merkle proof for id_key and are vectors of elements of 32 and 1 bytes, respectively (not. Vec<>).
  ## x is the x coordinate of the Shamir's secret share for which the proof is computed
  ## epoch is the input epoch (equivalently, the nullifier)
  ## the return bool value indicates the success or failure of the operation

  proc zk_verify*(ctx: ptr RLN,
               proof_buffer: ptr Buffer,
               proof_is_valid_ptr: ptr bool): bool {.importc: "verify".}
  ## Verifies the zkSNARK proof passed in proof_buffer
  ## input_buffer is serialized as input_data as [ proof<128> ]
  ## the verification of the zk proof is available in proof_is_valid_ptr, where a value of true indicates success and false a failure
  ## the return bool value indicates the success or failure of the operation

  #----------------------------------------------------------------------------------------------

  #-------------------------------- Common procedures -------------------------------------------
  proc new_circuit*(tree_height: uint, input_buffer: ptr Buffer, ctx: ptr (ptr RLN)): bool {.importc: "new".}
  ## creates an instance of rln object as defined by the zerokit RLN lib
  ## tree_height represent the depth of the Merkle tree
  ## input_buffer contains a serialization of the path where the circuit resources can be found (.r1cs, .wasm, .zkey and optionally the verification_key.json)
  ## ctx holds the final created rln object
  ## the return bool value indicates the success or failure of the operation

  proc new_circuit_from_data*(tree_height: uint, circom_buffer: ptr Buffer, zkey_buffer: ptr Buffer, vk_buffer: ptr Buffer, ctx: ptr (ptr RLN)): bool {.importc: "new_with_params".}
  ## creates an instance of rln object as defined by the zerokit RLN lib by passing the required inputs as byte arrays
  ## tree_height represent the depth of the Merkle tree
  ## circom_buffer contains the bytes read from the Circom .wasm circuit
  ## zkey_buffer contains the bytes read from the .zkey proving key
  ## vk_buffer contains the bytes read from the verification_key.json
  ## ctx holds the final created rln object
  ## the return bool value indicates the success or failure of the operation

  proc hash*(ctx: ptr RLN,
             input_buffer: ptr Buffer,
             output_buffer: ptr Buffer): bool {.importc: "hash".}
  ## it hashes (sha256) the plain text supplied in inputs_buffer and then maps it to a field element
  ## this proc is used to map arbitrary signals to field element for the sake of proof generation
  ## inputs_buffer holds the hash input as a byte seq 
  ## the hash output is generated and populated inside output_buffer 
  ## the output_buffer contains 32 bytes hash output 

{.pop.}
