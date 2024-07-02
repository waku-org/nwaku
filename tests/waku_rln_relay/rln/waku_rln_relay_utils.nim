import std/tempfiles

import waku/waku_rln_relay, waku/waku_rln_relay/[rln, protocol_types]

proc createRLNInstanceWrapper*(): RLNResult =
  return createRlnInstance(tree_path = genTempPath("rln_tree", "waku_rln_relay"))

proc unsafeAppendRLNProof*(
    rlnPeer: WakuRLNRelay, msg: var WakuMessage, senderEpochTime: float64
): RlnRelayResult[void] =
  ## this proc derived from appendRLNProof, does not perform nonce check to
  ## facilitate bad message id generation for testing

  let input = msg.toRLNSignal()
  let epoch = rlnPeer.calcEpoch(senderEpochTime)

  # we do not fetch a nonce from the nonce manager,
  # instead we use 0 as the nonce
  let proof = rlnPeer.groupManager.generateProof(input, epoch, 0).valueOr:
    return err("could not generate rln-v2 proof: " & $error)

  msg.proof = proof.encode().buffer
  return ok()
