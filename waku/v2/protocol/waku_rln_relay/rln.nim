# this module contains the Nim wrappers for the rln library https://github.com/kilic/rln/blob/3bbec368a4adc68cd5f9bfae80b17e1bbb4ef373/src/ffi.rs

import stew/byteutils, os
from strutils import rsplit

template sourceDir: string = currentSourcePath.rsplit(DirSep, 1)[0]
const libName* = sourceDir / "librln.dylib" # TODO may need to  load different libs based on OS type

# data types -----------------------------
# pub struct Buffer {
#     pub ptr: *const u8,
#     pub len: usize,
# }

type
  Buffer* = object
    `ptr`*: pointer
    len: csize_t
  RLNBn256* = pointer

# Procedures ------------------------------
 # all the following procedures are Nim wrappers for the libName
{.push dynlib: libName.}

# pub extern "C" fn new_circuit_from_params(
#     merkle_depth: usize,
#     parameters_buffer: *const Buffer,
#     ctx: *mut *mut RLN<Bn256>,
# ) -> bool 
proc newCircuitFromParams(merkle_depth: csize_t, parameters_buffer: ptr Buffer, ctx: ptr RLNBn256){.importc: "new_circuit_from_params".}

# pub extern "C" fn key_gen(ctx: *const RLN<Bn256>, keypair_buffer: *mut Buffer) -> bool
proc keyGen(ctx: RLNBn256, keypair_buffer: ptr Buffer): bool {.importc: "key_gen".}


# pub extern "C" fn hash(
#     ctx: *const RLN<Bn256>,
#     inputs_buffer: *const Buffer,
#     input_len: *const usize,
#     output_buffer: *mut Buffer,
# ) -> bool 
proc hash(ctx: ptr RLNBn256, inputs_buffer:ptr Buffer, input_len: ptr csize_t, output_buffer: ptr Buffer ) {.importc: "hash".}

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
# Tests -------------------------------------
var merkleDepth: csize_t = 5
var parameters = readFile(sourceDir / "parameters.key")
var pbytes = parameters.toBytes()
echo pbytes.len
var len : csize_t = uint(pbytes.len)
var parametersBuffer = Buffer(`ptr`: unsafeAddr parameters, len: len)
var cData: array[1024, byte]
var ctx : RLNBn256 = unsafeAddr cData
newCircuitFromParams(merkleDepth, unsafeAddr parametersBuffer,  unsafeAddr  ctx)
# echo "ctx ", ctx
var keys : array[64, byte]  
var keysLen : csize_t = 64
var keysBuffer: Buffer = Buffer(`ptr`: unsafeAddr keys, len: keysLen)
var done = keyGen(ctx, unsafeAddr keysBuffer) 
echo done
if done:
  var generatedKeys = cast[ptr array[64, byte]](keysBuffer.`ptr`)[]
  echo generatedKeys