import
  std/options,
  testutils/unittests,
  chronicles,
  chronos,
  stew/shims/net as stewNet,
  eth/keys,
  bearssl,
  stew/[results],
  metrics,
  metrics/chronos_httpserver

import
  waku/waku_rln_relay,
  waku/waku_rln_relay/rln,
  waku/waku_rln_relay/rln/wrappers,
  ./waku_rln_relay_utils,
  ../../testlib/[simple_mock, assertions],
  ../../waku_keystore/utils

from std/times import epochTime

const Empty32Array = default(array[32, byte])

proc valid(x: seq[byte]): bool =
  if x.len != 32:
    error "Length should be 32", length = x.len
    return false

  if x == Empty32Array:
    error "Should not be empty array", array = x
    return false

  return true

suite "membershipKeyGen":
  var rlnRes {.threadvar.}: RLNResult

  setup:
    rlnRes = createRLNInstanceWrapper()

  test "ok":
    # Given we generate valid membership keys
    let identityCredentialsRes = membershipKeyGen(rlnRes.get())

    # Then it contains valid identity credentials
    let identityCredentials = identityCredentialsRes.get()

    check:
      identityCredentials.idTrapdoor.valid()
      identityCredentials.idNullifier.valid()
      identityCredentials.idSecretHash.valid()
      identityCredentials.idCommitment.valid()

  test "done is false":
    # Given the key_gen function fails
    let backup = key_gen
    mock(key_gen):
      proc keyGenMock(ctx: ptr RLN, output_buffer: ptr Buffer): bool =
        return false

      keyGenMock

    # When we generate the membership keys
    let identityCredentialsRes = membershipKeyGen(rlnRes.get())

    # Then it fails
    check:
      identityCredentialsRes.error() == "error in key generation"

    # Cleanup
    mock(key_gen):
      backup

  test "generatedKeys length is not 128":
    # Given the key_gen function succeeds with wrong values
    let backup = key_gen
    mock(key_gen):
      proc keyGenMock(ctx: ptr RLN, output_buffer: ptr Buffer): bool =
        echo "# RUNNING MOCK"
        output_buffer.len = 0
        output_buffer.ptr = cast[ptr uint8](newSeq[byte](0))
        return true

      keyGenMock

    # When we generate the membership keys
    let identityCredentialsRes = membershipKeyGen(rlnRes.get())

    # Then it fails
    check:
      identityCredentialsRes.error() == "keysBuffer is of invalid length"

    # Cleanup
    mock(key_gen):
      backup

suite "RlnConfig":
  suite "createRLNInstance":
    test "ok":
      # When we create the RLN instance
      let rlnRes: RLNResult = createRLNInstance(15, "my.db")

      # Then it succeeds
      check:
        rlnRes.isOk()

    test "default":
      # When we create the RLN instance
      let rlnRes: RLNResult = createRLNInstance()

      # Then it succeeds
      check:
        rlnRes.isOk()

    test "new_circuit fails":
      # Given the new_circuit function fails
      let backup = new_circuit
      mock(new_circuit):
        proc newCircuitMock(
            tree_height: uint, input_buffer: ptr Buffer, ctx: ptr (ptr RLN)
        ): bool =
          return false

        newCircuitMock

      # When we create the RLN instance
      let rlnRes: RLNResult = createRLNInstance(15, "my.db")

      # Then it fails
      check:
        rlnRes.error() == "error in parameters generation"

      # Cleanup
      mock(new_circuit):
        backup

  suite "proofGen":
    test "Valid zk proof":
      # this test vector is from zerokit
      let rlnInstanceRes = createRLNInstanceWrapper()
      assertResultOk(rlnInstanceRes)
      let rlnInstance = rlnInstanceRes.value

      let identityCredential = defaultIdentityCredential()
      assert rlnInstance.insertMember(identityCredential.idCommitment)

      let merkleRootRes = rlnInstance.getMerkleRoot()
      assertResultOk(merkleRootRes)
      let merkleRoot = merkleRootRes.value

      let proofGenRes = rlnInstance.proofGen(
        data = @[],
        memKeys = identityCredential,
        memIndex = MembershipIndex(0),
        epoch = uint64(epochTime() / 1.float64).toEpoch(),
      )
      assertResultOk(proofGenRes)

      let
        rateLimitProof = proofGenRes.value
        proofVerifyRes = rlnInstance.proofVerify(
          data = @[], proof = rateLimitProof, validRoots = @[merkleRoot]
        )

      assertResultOk(proofVerifyRes)
      assert proofVerifyRes.value, "proof verification failed"

      # Assert the proof fields adhere to the specified types and lengths
      check:
        typeEq(rateLimitProof.proof, array[256, byte])
        typeEq(rateLimitProof.merkleRoot, array[32, byte])
        typeEq(rateLimitProof.shareX, array[32, byte])
        typeEq(rateLimitProof.shareY, array[32, byte])
        typeEq(rateLimitProof.nullifier, array[32, byte])
