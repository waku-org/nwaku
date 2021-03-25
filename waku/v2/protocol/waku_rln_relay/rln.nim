# this module contains the Nim wrappers for the rln library https://github.com/kilic/rln/blob/3bbec368a4adc68cd5f9bfae80b17e1bbb4ef373/src/ffi.rs

import os


const libPath = "vendor/rln/target/debug/"
when defined(Windows):
  const libName* = libPath / "rln.dll"
elif defined(Linux):
  const libName* = libPath / "librln.so"
elif defined(MacOsX):
  const libName* = libPath / "librln.dylib"

 # all the following procedures are Nim wrappers for the functions defined in libName
{.push dynlib: libName.}

type RLN*[E] {.incompleteStruct.} = object
type Bn256* = pointer

## Buffer struct is taken from
# https://github.com/celo-org/celo-threshold-bls-rs/blob/master/crates/threshold-bls-ffi/src/ffi.rs
type Buffer* = object
  `ptr`*: ptr uint8
  len*: uint

proc key_gen*(ctx: ptr RLN[Bn256], keypair_buffer: ptr Buffer): bool {.importc: "key_gen".}

proc new_circuit_from_params*(merkle_depth: uint,
                              parameters_buffer: ptr Buffer,
                              ctx: ptr (ptr RLN[Bn256])): bool {.importc: "new_circuit_from_params".}

#------------------------------Merkle Tree operations -----------------------------------------
proc update_next_member*(ctx: ptr RLN[Bn256],
                         input_buffer: ptr Buffer): bool {.importc: "update_next_member".}

proc delete_member*(ctx: ptr RLN[Bn256], index: uint): bool {.importc: "delete_member".}

proc get_root*(ctx: ptr RLN[Bn256], output_buffer: ptr Buffer): bool {.importc: "get_root".}
#----------------------------------------------------------------------------------------------

{.pop.}
