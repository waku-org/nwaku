import 
  chronicles, options, chronos, stint,
  web3,
  stew/byteutils,
  eth/keys
  
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