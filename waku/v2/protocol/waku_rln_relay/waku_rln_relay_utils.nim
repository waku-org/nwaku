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

proc membershipKeyGen*(inCtx: Option[ptr RLN[Bn256]] = none(ptr RLN[Bn256])): Option[MembershipKeyPair] =
  ## generates a MembershipKeyPair that can be used for the registration into the rln membership contract
  var ctx: ptr RLN[Bn256]
  if inCtx.isSome():
    ctx = inCtx.get()
  else:
    let genCtx = createRLNInstance(32)
    if genCtx.isNone():
      debug "error in rln instance creation"
      return none(MembershipKeyPair)
    ctx = genCtx.get()
    
  # keysBufferPtr will hold the generated key pairs i.e., secret and public keys 
  var 
    keysBuffer : Buffer
    keysBufferPtr = unsafeAddr(keysBuffer)
    done = key_gen(ctx, keysBufferPtr)  

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