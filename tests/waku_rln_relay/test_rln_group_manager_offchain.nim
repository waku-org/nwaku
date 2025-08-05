{.used.}

{.push raises: [].}

import
  testutils/unittests,
  results,
  options,
  waku/[
    waku_rln_relay/protocol_types,
    waku_rln_relay/rln,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/off_chain/group_manager,
  ]

import chronos, libp2p/crypto/crypto, eth/keys, dnsdisc/builder

import std/tempfiles

proc generateCredentials(rlnInstance: ptr RLN): IdentityCredential =
  let credRes = membershipKeyGen(rlnInstance)
  return credRes.get()

proc generateCredentials(rlnInstance: ptr RLN, n: int): seq[IdentityCredential] =
  var credentials: seq[IdentityCredential]
  for i in 0 ..< n:
    credentials.add(generateCredentials(rlnInstance))
  return credentials

suite "Static group manager":
  setup:
    let rlnInstance = createRlnInstance(
      tree_path = genTempPath("rln_tree", "group_manager_static")
    ).valueOr:
      raiseAssert $error

    let credentials = generateCredentials(rlnInstance, 10)

    let manager {.used.} = OffchainGroupManager(
      rlnInstance: rlnInstance,
      groupSize: 10,
      membershipIndex: some(MembershipIndex(5)),
      groupKeys: credentials,
    )