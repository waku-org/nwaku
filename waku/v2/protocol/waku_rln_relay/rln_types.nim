import 
  stint,
  stew/endians2

# types specific to RLN 
type RLN* {.incompleteStruct.} = object
type
  # identity key as defined in https://hackmd.io/tMTLMYmTR5eynw2lwK9n1w?view#Membership
  IDKey* = array[32, byte]
  # hash of identity key as defined ed in https://hackmd.io/tMTLMYmTR5eynw2lwK9n1w?view#Membership
  IDCommitment* = array[32, byte]
  MerkleNode* = array[32, byte] # Each node of the Merkle tee is a Poseidon hash which is a 32 byte value
  Nullifier* = array[32, byte]
  Epoch* = array[32, byte]
  RlnIdentifier* = array[32, byte]
  MembershipIndex* = uint

proc inHex*(value: IDKey or IDCommitment or MerkleNode or Nullifier or Epoch or RlnIdentifier): string = 
  var valueHex = (UInt256.fromBytesLE(value)).toHex
  # We pad leading zeroes
  while valueHex.len < value.len * 2:
    valueHex = "0" & valueHex
  return valueHex