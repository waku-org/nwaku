# this module contains the Nim wrappers for the rln library https://github.com/kilic/rln/blob/3bbec368a4adc68cd5f9bfae80b17e1bbb4ef373/src/ffi.rs

import os

# librln.dylib is the rln library taken from https://github.com/kilic/rln (originally implemented in rust with an exposed C API)  
# contains the key generation and other relevant functions

const libPath = "rln/target/debug/"
when defined(Windows):
  const libName* = libPath / "rln.dll"
elif defined(Linux):
  const libName* = libPath / "librln.so"
elif defined(MacOsX):
  const libName* = libPath / "librln.dylib"

# Data types -----------------------------

# pub struct Buffer {
#     pub ptr: *const u8,
#     pub len: usize,
# }

type
  Buffer* = object
    `ptr`*: pointer
    len*: csize_t
  RLNBn256* = object

# Procedures ------------------------------
 # all the following procedures are Nim wrappers for the functions defined in libName
{.push dynlib: libName.}

# pub extern "C" fn new_circuit_from_params(
#     merkle_depth: usize,
#     index: usize,
#     parameters_buffer: *const Buffer,
#     ctx: *mut *mut RLN<Bn256>,
# ) -> bool
proc newCircuitFromParams*(merkle_depth: csize_t, parameters_buffer: ptr Buffer, ctx: var  ptr RLNBn256): bool{.importc: "new_circuit_from_params".}

# pub extern "C" fn key_gen(ctx: *const RLN<Bn256>, keypair_buffer: *mut Buffer) -> bool
proc keyGen*(ctx: ptr RLNBn256, keypair_buffer: var Buffer): bool {.importc: "key_gen".}


# pub extern "C" fn hash(
#     ctx: *const RLN<Bn256>,
#     inputs_buffer: *const Buffer,
#     input_len: *const usize,
#     output_buffer: *mut Buffer,
# ) -> bool 
proc hash*(ctx: ptr RLNBn256, inputs_buffer:ptr Buffer, input_len: ptr csize_t, output_buffer: ptr Buffer ) {.importc: "hash".} #TODO not tested yet

# pub extern "C" fn verify(
#     ctx: *const RLN<Bn256>,
#     proof_buffer: *const Buffer,
#     public_inputs_buffer: *const Buffer,
#     result_ptr: *mut u32,
# ) -> bool



# pub extern "C" fn generate_proof(
#     ctx: *const RLN<Bn256>,
#     input_buffer: *const Buffer,
#     output_buffer: *mut Buffer,
# ) -> bool

{.pop.}