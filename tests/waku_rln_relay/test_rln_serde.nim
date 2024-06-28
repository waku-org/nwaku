{.used.}

{.push raises: [].}

import
  ./rln/waku_rln_relay_utils,
  waku_keystore/protocol_types,
  waku_rln_relay,
  waku_rln_relay/rln

import testutils/unittests
import stew/results, stint
from std/times import epochTime

func fromStrToBytesLe(v: string): seq[byte] =
  try:
    return @(hexToUint[256](v).toBytesLE())
  except ValueError:
    # this should never happen
    return @[]

func defaultIdentityCredential*(): IdentityCredential =
  # zero out the values we don't need
  return IdentityCredential(
    idTrapdoor: default(IdentityTrapdoor),
    idNullifier: default(IdentityNullifier),
    idSecretHash: fromStrToBytesLe(
      "7984f7c054ad7793d9f31a1e9f29eaa8d05966511e546bced89961eb8874ab9"
    ),
    idCommitment: fromStrToBytesLe(
      "51c31de3bff7e52dc7b2eb34fc96813bacf38bde92d27fe326ce5d8296322a7"
    ),
  )

func defaultRateCommitment*(): RateCommitment =
  let idCredential = defaultIdentityCredential()
  return RateCommitment(idCommitment: idCredential.idCommitment, userMessageLimit: 100)

suite "RLN Relay v2: serde":
  test "toLeaf: converts a rateCommitment to a valid leaf":
    # this test vector is from zerokit
    let rateCommitment = defaultRateCommitment()

    let leafRes = toLeaf(rateCommitment)
    assert leafRes.isOk(), $leafRes.error

    let expectedLeaf =
      "09beac7784abfadc9958b3176b352389d0b969ccc7f8bccf3e968ed632e26eca"
    check expectedLeaf == leafRes.value.inHex()

  test "proofGen: generates a valid zk proof":
    # this test vector is from zerokit
    let rlnInstance = createRLNInstanceWrapper()
    assert rlnInstance.isOk, $rlnInstance.error
    let rln = rlnInstance.value

    let credential = defaultIdentityCredential()
    let rateCommitment = defaultRateCommitment()
    let success = rln.insertMember(@(rateCommitment.toLeaf().value))
    let merkleRootRes = rln.getMerkleRoot()
    assert merkleRootRes.isOk, $merkleRootRes.error
    let merkleRoot = merkleRootRes.value

    assert success, "failed to insert member"

    let proofRes = rln.proofGen(
      data = @[],
      membership = credential,
      userMessageLimit = rateCommitment.userMessageLimit,
      messageId = 0,
      index = 0,
      epoch = uint64(epochTime() / 1.float64).toEpoch(),
    )

    assert proofRes.isOk, $proofRes.error

    let proof = proofRes.value

    let proofVerifyRes =
      rln.proofVerify(data = @[], proof = proof, validRoots = @[merkleRoot])

    assert proofVerifyRes.isOk, $proofVerifyRes.error
    assert proofVerifyRes.value, "proof verification failed"
