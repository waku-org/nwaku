import 
  chronicles, options, chronos, stint, sequtils,
  web3,
  stew/byteutils,
  eth/keys,
  rln 

type MembershipKeyPair* = object 
  secretKey*: array[32, byte]
  publicKey*: array[32, byte]

type WakuRLNRelay* = object 
  membershipKeyPair*: MembershipKeyPair
  ethClientAddress*: string
  ethAccountAddress*: Address
  # this field is required for signing transactions
  # TODO may need to erase this ethAccountPrivateKey when is not used
  # TODO may need to make ethAccountPrivateKey mandatory
  ethAccountPrivateKey*: Option[PrivateKey]
  membershipContractAddress*: Address

# inputs of the membership contract constructor
const 
    MembershipFee* = 5.u256
    Depth* = 32.u256
    # TODO the EthClient should be an input to the rln-relay
    EthClient* = "ws://localhost:8540/"

# membership contract interface
contract(MembershipContract):
  # TODO define a return type of bool for register method to signify a successful registration
  proc register(pubkey: Uint256) # external payable

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

proc register*(rlnPeer: WakuRLNRelay): Future[bool] {.async.} =
  ## registers the public key of the rlnPeer which is rlnPeer.membershipKeyPair.publicKey
  ## into the membership contract whose address is in rlnPeer.membershipContractAddress
  let web3 = await newWeb3(rlnPeer.ethClientAddress)
  web3.defaultAccount = rlnPeer.ethAccountAddress
  # when the private key is set in a web3 instance, the send proc (sender.register(pk).send(MembershipFee))
  # does the signing using the provided key
  web3.privateKey = rlnPeer.ethAccountPrivateKey
  var sender = web3.contractSender(MembershipContract, rlnPeer.membershipContractAddress) # creates a Sender object with a web3 field and contract address of type Address
  let pk = cast[UInt256](rlnPeer.membershipKeyPair.publicKey)
  discard await sender.register(pk).send(MembershipFee)
  # TODO check the receipt and then return true/false
  await web3.close()
  return true 

proc proofGen*(data: seq[byte]): seq[byte] =
  # TODO to implement the actual proof generation logic
  return "proof".toBytes() 

proc proofVrfy*(data, proof: seq[byte]): bool =
  # TODO to implement the actual proof verification logic
  return true