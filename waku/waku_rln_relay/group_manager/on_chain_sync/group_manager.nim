{.push raises: [].}

import
  std/[tables, options],
  chronos,
  web3,
  stint,
  ../on_chain/group_manager as onchain,
  ../../rln,
  ../../conversion_utils

logScope:
  topics = "waku rln_relay onchain_sync_group_manager"

type OnChainSyncGroupManager* = ref object of OnchainGroupManager
  # Cache for merkle proofs by index
  merkleProofsByIndex*: Table[Uint256, seq[Uint256]]

method generateProof*(
    g: OnChainSyncGroupManager,
    data: seq[byte],
    epoch: Epoch,
    messageId: MessageId,
    rlnIdentifier = DefaultRlnIdentifier,
): Future[GroupManagerResult[RateLimitProof]] {.async.} =
  ## Generates an RLN proof using the cached Merkle proof and custom witness
  # Ensure identity credentials and membership index are set
  if g.idCredentials.isNone():
    return err("identity credentials are not set")
  if g.membershipIndex.isNone():
    return err("membership index is not set")
  if g.userMessageLimit.isNone():
    return err("user message limit is not set")

  # Retrieve the cached Merkle proof for the membership index
  let index = stuint(g.membershipIndex.get(), 256)

  if not g.merkleProofsByIndex.hasKey(index):
    try:
      let merkleProofInvocation = g.wakuRlnContract.get().merkleProofElements(index)
      let merkleProof = await merkleProofInvocation.call()
      g.merkleProofsByIndex[index] = merkleProof
    except CatchableError:
      return err("Failed to fetch merkle proof: " & getCurrentExceptionMsg())

  let merkleProof = g.merkleProofsByIndex[index]
  if merkleProof.len == 0:
    return err("Merkle proof not found")

  # Prepare the witness
  let witness = Witness(
    identity_secret: g.idCredentials.get().idSecretHash,
    identity_nullifier: g.idCredentials.get().idNullifier,
    merkle_proof: merkleProof,
    external_nullifier: epoch,
    signal: data,
    message_id: messageId,
    rln_identifier: rlnIdentifier,
  )
  let serializedWitness = serialize(witness)
  var inputBuffer = toBuffer(serializedWitness)

  # Generate the proof using the zerokit API
  var outputBuffer: Buffer
  let success =
    generate_proof_with_witness(g.rlnInstance, addr inputBuffer, addr outputBuffer)
  if not success:
    return err("Failed to generate proof")

  # Parse the proof into a RateLimitProof object
  var proofValue = cast[ptr array[320, byte]](outputBuffer.`ptr`)
  let proofBytes: array[320, byte] = proofValue[]

  ## parse the proof as [ proof<128> | root<32> | external_nullifier<32> | share_x<32> | share_y<32> | nullifier<32> ]
  let
    proofOffset = 128
    rootOffset = proofOffset + 32
    externalNullifierOffset = rootOffset + 32
    shareXOffset = externalNullifierOffset + 32
    shareYOffset = shareXOffset + 32
    nullifierOffset = shareYOffset + 32

  var
    zkproof: ZKSNARK
    proofRoot, shareX, shareY: MerkleNode
    externalNullifier: ExternalNullifier
    nullifier: Nullifier

  discard zkproof.copyFrom(proofBytes[0 .. proofOffset - 1])
  discard proofRoot.copyFrom(proofBytes[proofOffset .. rootOffset - 1])
  discard
    externalNullifier.copyFrom(proofBytes[rootOffset .. externalNullifierOffset - 1])
  discard shareX.copyFrom(proofBytes[externalNullifierOffset .. shareXOffset - 1])
  discard shareY.copyFrom(proofBytes[shareXOffset .. shareYOffset - 1])
  discard nullifier.copyFrom(proofBytes[shareYOffset .. nullifierOffset - 1])

  # Create the RateLimitProof object
  let output = RateLimitProof(
    proof: zkproof,
    merkleRoot: proofRoot,
    externalNullifier: externalNullifier,
    epoch: epoch,
    rlnIdentifier: rlnIdentifier,
    shareX: shareX,
    shareY: shareY,
    nullifier: nullifier,
  )
  return ok(output)