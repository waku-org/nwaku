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

proc fetchMerkleProof*(g: OnchainSyncGroupManager) {.async.} =
  let index = stuint(g.membershipIndex.get(), 256)
  try:
    let merkleProofInvocation = g.wakuRlnContract.get().merkleProofElements(index)
    let merkleProof = await merkleProofInvocation.call()
      # Await the contract call and extract the result
    return merkleProof
  except CatchableError:
    error "Failed to fetch merkle proof: " & getCurrentExceptionMsg()

proc fetchMerkleRoot*(g: OnchainSyncGroupManager) {.async.} =
  let merkleRootInvocation = g.wakuRlnContract.get().root()
  let merkleRoot = await merkleRootInvocation.call()
  return merkleRoot

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

  # Prepare the witness
  let witness = Witness(
    identity_secret: g.idCredentials.get().idSecretHash,
    user_message_limit: g.userMessageLimit.get(),
    message_id: messageId,
    path_elements: g.fetchMerkleProof(),
    identity_path_index: g.membershipIndex.get(),
    x: data,
    external_nullifier: poseidon_hash([epoch, rln_identifier]),
  )

  let serializedWitness = serialize(witness)
  var inputBuffer = toBuffer(serializedWitness)

  # Generate the proof using the zerokit API
  var outputBuffer: Buffer
  let success = generate_proof_with_witness(
    g.fetchMerkleRoot(), addr inputBuffer, addr outputBuffer
  )
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

method verifyProof*(
    g: OnChainSyncGroupManager, input: openArray[byte], proof: RateLimitProof
): GroupManagerResult[bool] {.base, gcsafe, raises: [].} =
  ## verifies the proof, returns an error if the proof verification fails
  ## returns true if the proof is valid
  var normalizedProof = proof
  # when we do this, we ensure that we compute the proof for the derived value
  # of the externalNullifier. The proof verification will fail if a malicious peer
  # attaches invalid epoch+rlnidentifier pair
  normalizedProof.externalNullifier = poseidon_hash([epoch, rln_identifier]).valueOr:
    return err("could not construct the external nullifier")

  var
    proofBytes = serialize(normalizedProof, data)
    proofBuffer = proofBytes.toBuffer()
    validProof: bool
    rootsBytes = serialize(validRoots)
    rootsBuffer = rootsBytes.toBuffer()

  trace "serialized proof", proof = byteutils.toHex(proofBytes)

  let verifyIsSuccessful = verify_with_roots(
    g.fetchMerkleRoot(), addr proofBuffer, addr rootsBuffer, addr validProof
  )
  if not verifyIsSuccessful:
    # something went wrong in verification call
    warn "could not verify validity of the proof", proof = proof
    return err("could not verify the proof")

  if not validProof:
    return ok(false)
  else:
    return ok(true)