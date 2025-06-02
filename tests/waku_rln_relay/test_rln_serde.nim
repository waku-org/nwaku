{.used.}

{.push raises: [].}

import results

import
  ./rln/waku_rln_relay_utils,
  waku/[
    waku_keystore/protocol_types,
    waku_rln_relay,
    waku_rln_relay/rln,
    waku_rln_relay/protocol_types,
  ],
  ../waku_keystore/utils,
  ../testlib/testutils,
  testutils/unittests

from std/times import epochTime

func defaultRateCommitment*(): RateCommitment =
  let idCredential = defaultIdentityCredential()
  return RateCommitment(idCommitment: idCredential.idCommitment, userMessageLimit: 100)

suite "RLN Relay v2: serde":
  xasyncTest "toLeaf: converts a rateCommitment to a valid leaf":
    # this test vector is from zerokit
    let rateCommitment = defaultRateCommitment()

    let leafRes = toLeaf(rateCommitment)
    assert leafRes.isOk(), $leafRes.error

    let expectedLeaf =
      "09beac7784abfadc9958b3176b352389d0b969ccc7f8bccf3e968ed632e26eca"
    check expectedLeaf == leafRes.value.inHex()

  xasyncTest "proofGen: generates a valid zk proof":
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
