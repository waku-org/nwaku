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

proc main(): Future[string] {.async, gcsafe.} =
  # Spin up a local Ethereum JSON-RPC (Anvil) and deploy the RLN contract
  let anvilProc = runAnvil()
  defer:
    stopAnvil(anvilProc)

  # Set up an On-chain group manager (includes contract deployment)
  let manager = await setupOnchainGroupManager()
  (await manager.init()).isOkOr:
    raiseAssert $error

  # Register a new member so that we can later generate proofs
  let idCredentials = generateCredentials(manager.rlnInstance)

  try:
    await manager.register(idCredentials, UserMessageLimit(100))
  except Exception, CatchableError:
    assert false, "exception raised: " & getCurrentExceptionMsg()

  let rootUpdated = await manager.updateRoots()

  if rootUpdated:
    let proofResult = await manager.fetchMerkleProofElements()
    if proofResult.isErr():
      error "Failed to fetch Merkle proof", error = proofResult.error
    manager.merkleProofCache = proofResult.get()

  let epoch = default(Epoch)
  debug "epoch in bytes", epochHex = epoch.inHex()
  let data: seq[byte] = newSeq[byte](1024)

  var proofGenTimes: seq[times.Duration] = @[]
  var proofVerTimes: seq[times.Duration] = @[]

  for i in 1 .. 100:
    var time = getTime()
    let proof = manager.generateProof(data, epoch, MessageId(i.uint8)).valueOr:
      raiseAssert $error
    proofGenTimes.add(getTime() - time)

    time = getTime()
    let ok = manager.verifyProof(data, proof).valueOr:
      raiseAssert $error
    proofVerTimes.add(getTime() - time)

  echo "Proof generation times: ", sum(proofGenTimes) div len(proofGenTimes)
  echo "Proof verification times: ", sum(proofVerTimes) div len(proofVerTimes)

when isMainModule:
  try:
    discard waitFor main()
  except CatchableError as e:
    raise e
