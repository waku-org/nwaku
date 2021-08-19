{.push raises: [Defect].}

import 
  options, chronos, stint,
  web3,
  eth/keys

## Bn256 and RLN are Nim wrappers for the data types used in 
## the rln library https://github.com/kilic/rln/blob/3bbec368a4adc68cd5f9bfae80b17e1bbb4ef373/src/ffi.rs
type Bn256* = pointer
type RLN*[E] = pointer


# Custom data types defined for waku rln relay -------------------------
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
# TODO may be able to make these constants private and put them inside the waku_rln_relay_utils
const 
  MembershipFee* = 5.u256
  Depth* = 32.u256
  # TODO the EthClient should be an input to the rln-relay
  EthClient* = "ws://localhost:8540/"