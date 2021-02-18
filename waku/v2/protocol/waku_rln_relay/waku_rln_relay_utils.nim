import 
  chronicles, options, chronos, stint,
  stew/byteutils,
  rln 

type MembershipKeyPair* = object 
  secretKey*: array[32, byte]
  publicKey*: array[32, byte]


proc membershipKeyGen*(): Option[MembershipKeyPair] =
  # generates a MembershipKeyPair that can be used for the registration into the rln membership contract
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

  # check the parameters.key is not empty
  if(pbytes.len == 0):
    debug "error in parameters.key"
    return none(MembershipKeyPair)
    
  # ctx holds the information that is going to be used for  the key generation
  var 
    obj = RLNBn256()
    objPtr = unsafeAddr(obj)
    ctx = objPtr
  let res = newCircuitFromParams(merkleDepth, unsafeAddr parametersBuffer, ctx)

  # check whether the circuit parameters are generated successfully
  if(res == false):
    debug "error in parameters generation"
    return none(MembershipKeyPair)
    
  # keysBufferPtr will hold the generated key pairs i.e., secret and public keys 
  var 
    keysBufferPtr : Buffer
    done = keyGen(ctx, keysBufferPtr) 

  # check whether the keys are generated successfully
  if(done == false):
    debug "error in key generation"
    return none(MembershipKeyPair)
    
  var generatedKeys = cast[ptr array[64, byte]](keysBufferPtr.`ptr`)[]
  # the public and secret keys together are 64 bytes
  if (generatedKeys.len != 64):
    debug "the generated keys are invalid"
    return none(MembershipKeyPair)
  
  var 
    secret = cast[array[32, byte]](generatedKeys[0..31])
    public = cast[array[32, byte]](generatedKeys[31..^1])
    keypair = MembershipKeyPair(secretKey: secret, publicKey: public)

  return some(keypair)