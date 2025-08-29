import std/tempfiles

import waku/waku_rln_relay, waku/waku_rln_relay/[rln, protocol_types, nonce_manager]

proc createRLNInstanceWrapper*(): RLNResult =
  return createRlnInstance(tree_path = genTempPath("rln_tree", "waku_rln_relay"))

proc unsafeAppendRLNProof*(
    rlnPeer: WakuRLNRelay, msg: var WakuMessage, epoch: Epoch, messageId: MessageId
): RlnRelayResult[void] =
  ## Test helper derived from `appendRLNProof`.
  ## - Skips nonce validation to intentionally allow generating "bad" message IDs for tests.
  ## - Forces a real-time on-chain Merkle root refresh via `updateRoots()` and fetches Merkle
  ##   proof elements, updating `merkleProofCache` (bypasses `trackRootsChanges`).
  ## WARNING: For testing only

  let manager = cast[OnchainGroupManager](rlnPeer.groupManager)
  let rootUpdated = waitFor manager.updateRoots()

  # Fetch Merkle proof either when a new root was detected *or* when the cache is empty.
  if rootUpdated or manager.merkleProofCache.len == 0:
    let proofResult = waitFor manager.fetchMerkleProofElements()
    if proofResult.isErr():
      error "Failed to fetch Merkle proof", error = proofResult.error
    manager.merkleProofCache = proofResult.get()

  let proof = manager.generateProof(msg.payload, epoch, messageId).valueOr:
    return err("could not generate rln-v2 proof: " & $error)

  msg.proof = proof.encode().buffer
  return ok()

proc getWakuRlnConfig*(
    manager: OnchainGroupManager,
    userMessageLimit: uint64 = 1,
    epochSizeSec: uint64 = 1,
    treePath: string = genTempPath("rln_tree", "waku_rln_relay"),
    index: MembershipIndex = MembershipIndex(0),
): WakuRlnConfig =
  let wakuRlnConfig = WakuRlnConfig(
    dynamic: true,
    ethClientUrls: @[EthClient],
    ethContractAddress: manager.ethContractAddress,
    chainId: manager.chainId,
    credIndex: some(index),
    userMessageLimit: userMessageLimit,
    epochSizeSec: epochSizeSec,
    treePath: treePath,
    ethPrivateKey: some(manager.ethPrivateKey.get()),
    onFatalErrorAction: proc(errStr: string) =
      warn "non-fatal onchain test error", errStr
    ,
  )
  return wakuRlnConfig
