import
  math,
  std/sequtils,
  stew/results,
  options,
  ../../waku/waku_rln_relay/protocol_types,
  ../../waku/waku_rln_relay/rln,
  ../../waku/waku_rln_relay,
  ../../waku/waku_rln_relay/conversion_utils,
  ../../waku/waku_rln_relay/group_manager/static/group_manager

import std/[times, os]

proc main(): Future[string] {.async, gcsafe.} =
  let rlnIns = createRLNInstance(20).get()
  let credentials = toSeq(0 .. 1000).mapIt(membershipKeyGen(rlnIns).get())

  let manager = StaticGroupManager(
    rlnInstance: rlnIns,
    groupSize: 1000,
    membershipIndex: some(MembershipIndex(900)),
    groupKeys: credentials,
  )

  await manager.init()

  let data: seq[byte] = newSeq[byte](1024)

  var proofGenTimes: seq[times.Duration] = @[]
  var proofVerTimes: seq[times.Duration] = @[]
  for i in 0 .. 50:
    var time = getTime()
    let proof = manager.generateProof(data, getCurrentEpoch()).get()
    proofGenTimes.add(getTime() - time)

    time = getTime()
    let res = manager.verifyProof(data, proof).get()
    proofVerTimes.add(getTime() - time)

  echo "Proof generation times: ", sum(proofGenTimes) div len(proofGenTimes)
  echo "Proof verification times: ", sum(proofVerTimes) div len(proofVerTimes)

when isMainModule:
  try:
    waitFor(main())
  except CatchableError as e:
    raise e
