# this module contains the Nim wrappers for the rln library https://github.com/kilic/rln/blob/3bbec368a4adc68cd5f9bfae80b17e1bbb4ef373/src/ffi.rs

{.push raises: [Defect].}

import
  os,
  waku_rln_relay_types

const libPath = "vendor/rln/target/debug/"
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

{.pop.}
