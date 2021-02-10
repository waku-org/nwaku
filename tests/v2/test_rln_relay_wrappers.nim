{.used.}

import
  std/[unittest],
  stew/byteutils,
  chronicles,
  ../../waku/v2/protocol/waku_rln_relay/rln  

suite "Waku rln relay":
  test "rln lib: Keygen Nim Wrappers":
    var 
      merkleDepth: csize_t = 32
      # parameters.key contains the parameters related to the Poseidon hasher
      # to generate this file, clone this repo https://github.com/kilic/rln 
      # and run the following command in the root directory of the cloned project
      # cargo run --example export_test_keys
      # the file is generated separately and copied here
      parameters = readFile("waku/v2/protocol/waku_rln_relay/parameters.key")
      pbytes = parameters.toBytes()
      len : csize_t = uint(pbytes.len)
      parametersBuffer = Buffer(`ptr`: unsafeAddr(pbytes[0]), len: len)
    check:
      # check the parameters.key is not empty
      pbytes.len != 0

    # ctx holds the information that is going to be used for  the key generation
    var 
      obj = RLNBn256()
      objPtr = unsafeAddr(obj)
      ctx = objPtr
    let res = newCircuitFromParams(merkleDepth, unsafeAddr parametersBuffer, ctx)
    check:
      # check whether the circuit parameters are generated successfully
      res == true

    # keysBufferPtr will hold the generated key pairs i.e., secret and public keys 
    var 
      keysBufferPtr : Buffer
      done = keyGen(ctx, keysBufferPtr) 
    check:
      # check whether the keys are generated successfully
      done == true

    if done:
      var generatedKeys = cast[ptr array[64, byte]](keysBufferPtr.`ptr`)[]
      check:
        # the public and secret keys together are 64 bytes
        generatedKeys.len == 64
      debug "generated keys: ", generatedKeys 
    
