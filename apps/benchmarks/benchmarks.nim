import
  std/[strutils, times, sequtils, osproc], math, results, options, testutils/unittests

import
  waku/[
    waku_rln_relay/protocol_types,
    waku_rln_relay/rln,
    waku_rln_relay,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/on_chain/group_manager,
  ],
  tests/waku_rln_relay/utils_onchain

proc benchmark(
    manager: OnChainGroupManager, registerCount: int, messageLimit: int
): Future[string] {.async, gcsafe.} =
  # Register a new member so that we can later generate proofs
  let idCredentials = generateCredentials(manager.rlnInstance, registerCount)

  var start_time = getTime()
  for i in 0 .. registerCount - 1:
    try:
      await manager.register(idCredentials[i], UserMessageLimit(messageLimit + 1))
    except Exception, CatchableError:
      assert false, "exception raised: " & getCurrentExceptionMsg()

    debug "registration finished",
      iter = i, elapsed_ms = (getTime() - start_time).inMilliseconds

  discard await manager.updateRoots()
  let proofResult = await manager.fetchMerkleProofElements()
  if proofResult.isErr():
    error "Failed to fetch Merkle proof", error = proofResult.error
  manager.merkleProofCache = proofResult.get()

  let epoch = default(Epoch)
  debug "epoch in bytes", epochHex = epoch.inHex()
  let data: seq[byte] = newSeq[byte](1024)

  var proofGenTimes: seq[times.Duration] = @[]
  var proofVerTimes: seq[times.Duration] = @[]

  start_time = getTime()
  for i in 1 .. messageLimit:
    var generate_time = getTime()
    let proof = manager.generateProof(data, epoch, MessageId(i.uint8)).valueOr:
      raiseAssert $error
    proofGenTimes.add(getTime() - generate_time)

    let verify_time = getTime()
    let ok = manager.verifyProof(data, proof).valueOr:
      raiseAssert $error
    proofVerTimes.add(getTime() - verify_time)
    debug "iteration finished",
      iter = i, elapsed_ms = (getTime() - start_time).inMilliseconds

  echo "Proof generation times: ", sum(proofGenTimes) div len(proofGenTimes)
  echo "Proof verification times: ", sum(proofVerTimes) div len(proofVerTimes)

proc main() =
  # Start a local Ethereum JSON-RPC (Anvil) so that the group-manager setup can connect.
  let anvilProc = runAnvil()
  defer:
    stopAnvil(anvilProc)

  # Set up an On-chain group manager (includes contract deployment)
  let manager = waitFor setupOnchainGroupManager()
  (waitFor manager.init()).isOkOr:
    raiseAssert $error

  discard waitFor benchmark(manager, 200, 20)

when isMainModule:
  main()
