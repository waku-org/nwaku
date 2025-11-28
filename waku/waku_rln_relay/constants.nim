import stint

import ./protocol_types

import ../waku_keystore

# Acceptable roots for merkle root validation of incoming messages
const AcceptableRootWindowSize* = 50

# RLN membership key and index files path
const RlnCredentialsFilename* = "rlnCredentials.txt"

# inputs of the membership contract constructor
# TODO may be able to make these constants private and put them inside the waku_rln_relay_utils
const
  # in wei
  MembershipFee* = 0.u256
  #  the current implementation of the rln lib supports a circuit for Merkle tree with depth 20
  MerkleTreeDepth* = 20
  EthClient* = "http://127.0.0.1:8540"

const
  # the size of poseidon hash output in bits
  HashBitSize* = 256
  # the size of poseidon hash output as the number hex digits
  HashHexSize* = int(HashBitSize / 4)

const DefaultRlnTreePath* = "rln_tree.db"

const
  # pre-processed "rln/waku-rln-relay/v2.0.0" to array[32, byte]
  DefaultRlnIdentifier*: RlnIdentifier = [
    114, 108, 110, 47, 119, 97, 107, 117, 45, 114, 108, 110, 45, 114, 101, 108, 97, 121,
    47, 118, 50, 46, 48, 46, 48, 0, 0, 0, 0, 0, 0, 0,
  ]
  DefaultUserMessageLimit* = UserMessageLimit(20)

# temporary variables to test waku-rln-relay performance in the static group mode
const
  StaticGroupSize* = 10000
  #  StaticGroupKeys is a static list of 10000 membership keys in the form of (identity trapdoor, identity nullifier, identity secret hash, identity commitment)
  #  keys are created locally, using createMembershipList proc from waku_rln_relay_utils module, and the results are hardcoded in here
  #  this list is temporary and is created to test the performance of waku-rln-relay for the static groups
  #  in the later versions, this static hardcoded group will be replaced with a dynamic one

const StaticGroupKeys* = @[]

# StaticGroupMerkleRoot is the root of the Merkle tree constructed from the StaticGroupKeys above
# rln-v2: rate commitments are used for the Merkle tree construction, defaulting the UserMessageLimit to 20
# the root is created locally, using createMembershipList proc from waku_rln_relay_utils module, and the result is hardcoded in here
const StaticGroupMerkleRoot* =
  "2c149e48886b5ba3da2edf8db8d7a364ae7a25618489c04cf0c0380f7cdd4d6f"

const MaxClockGapSeconds* = 20.0 # the maximum clock difference between peers in seconds

# RLN Keystore defaults
const RLNAppInfo* = AppInfo(
  application: "waku-rln-relay", appIdentifier: "01234567890abcdef", version: "0.2"
)
