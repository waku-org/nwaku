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

type Auth* = object
  secret_buffer*: ptr Buffer
  index*: uint
  
#------------------------------ Merkle Tree operations -----------------------------------------

proc update_next_member*(ctx: RLN[Bn256],
                        input_buffer: ptr Buffer): bool {.importc: "update_next_member".}

proc delete_member*(ctx: RLN[Bn256], index: uint): bool {.importc: "delete_member".}

proc get_root*(ctx: RLN[Bn256], output_buffer: ptr Buffer): bool {.importc: "get_root".}

#----------------------------------------------------------------------------------------------
#-------------------------------- zkSNARKs operations -----------------------------------------

proc key_gen*(ctx: RLN[Bn256], keypair_buffer: ptr Buffer): bool {.importc: "key_gen".}

proc generate_proof*(ctx: RLN[Bn256],
                    input_buffer: ptr Buffer,
                    output_buffer: ptr Buffer): bool {.importc: "generate_proof".}
## input_buffer serialized as  [ id_key<32> | id_index<8> | epoch<32> | signal_len<8> | signal<var> ]
## output_buffer holds the proof data and should be parsed as |proof<256>|root<32>|epoch<32>|share_x<32>|share_y<32>|nullifier<32>|
## sizes are in bytes
proc verify*(ctx: RLN[Bn256],
            proof_buffer: ptr Buffer,
            result_ptr: ptr uint32): bool {.importc: "verify".}
## proof_buffer [ proof<256>| root<32>| epoch<32>| share_x<32>| share_y<32>| nullifier<32> | signal_len<8> | signal<var> ]
#----------------------------------------------------------------------------------------------
#-------------------------------- Common procedures -------------------------------------------

proc new_circuit_from_params*(merkle_depth: uint,
                              parameters_buffer: ptr Buffer,
                              ctx: ptr RLN[Bn256]): bool {.importc: "new_circuit_from_params".}
                              
proc hash*(ctx: RLN[Bn256],
          inputs_buffer: ptr Buffer,
          output_buffer: ptr Buffer): bool {.importc: "signal_to_field".}

{.pop.}
