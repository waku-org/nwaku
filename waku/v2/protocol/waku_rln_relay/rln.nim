# this module contains the Nim wrappers for the rln library https://github.com/kilic/rln/blob/3bbec368a4adc68cd5f9bfae80b17e1bbb4ef373/src/ffi.rs

const libName* = "librln.dylib" # TODO may need to  load different libs based on OS type

# data types -----------------------------
# pub struct Buffer {
#     pub ptr: *const u8,
#     pub len: usize,
# }

type
  Buffer* = object
    `ptr`*: pointer
    len: csize_t
  RLNBn256* = object

# Procedures ------------------------------
 # all the following procedures are Nim wrappers for the libName
{.push dynlib: libName.}

# pub extern "C" fn new_circuit_from_params(
#     merkle_depth: usize,
#     parameters_buffer: *const Buffer,
#     ctx: *mut *mut RLN<Bn256>,
# ) -> bool 

proc new_circuit_from_params(merkle_depth: csize_t, parameters_buffer: ptr Buffer, ctx: var ptr RLNBn256){.importc: "new_circuit_from_params".}


# pub extern "C" fn key_gen(ctx: *const RLN<Bn256>, keypair_buffer: *mut Buffer) -> bool

proc key_gen(ctx: RLNBn256, keypair_buffer: var ptr Buffer) {.importc: "key_gen".}


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