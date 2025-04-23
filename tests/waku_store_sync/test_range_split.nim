import unittest, chronos, stew/byteutils, nimcrypto
import ../../waku/waku_store_sync/[reconciliation, common]
import ../../waku/waku_store_sync/storage/seq_storage
import ../../waku/waku_core/message/digest
import ../testlib/assertions
import nimcrypto

export MDigest

proc toDigest*(s: string): WakuMessageHash =
  let d = keccak256.digest(s.toBytes)  # d is MDigest[256] == 32 bytes
  var resultHash: WakuMessageHash
  for i in 0 ..< 32:
    resultHash[i] = d.data[i]
  return resultHash


suite "Waku Sync: Reconciliation Splits Mismatched Range":

  test "reconciliation produces subranges when fingerprints differ":
    let localStorage = SeqStorage.new(@[])
    for i in 0 ..< 8:
      let id = SyncID(time: 1000 + i, hash: toDigest("msg" & $i))
      discard localStorage.insert(id)

    let remoteStorage = SeqStorage.new(@[])
    for i in 0 ..< 8:
      var hash: WakuMessageHash
      if i == 3:
       hash = toDigest("msg" & $i)
      else:
       hash = toDigest("msg" & $i)

      let id = SyncID(time: 1000 + i, hash: hash)
      discard remoteStorage.insert(id)

    let fromId = SyncID(time: 1000, hash: toDigest("msg0"))
    let toId   = SyncID(time: 1008, hash: toDigest("msg7"))
    let bounds = fromId .. toId

    let localFp = localStorage.computeFingerprint(bounds)
    let remoteFp = remoteStorage.computeFingerprint(bounds)
    check localFp != remoteFp

    var sentRanges: seq[Range] = @[]

    proc dummySend(p: Payload) {.async.} =
      for (_, r) in p.ranges:
        sentRanges.add r

    let driver = newSeqDriver(localStorage)
    let context = ReconciliationContext(
      driver: driver,
      sendFn: dummySend,
      cluster: 0,
      shards: @[0]
    )

    let recon = Reconciliation.new(driver)

    let request: ReceivedPayload = (
      cluster: 0,
      shards: @[0],
      timestamp: 0'u64,
      ranges: @[(bounds, Range(kind: RangeType.Fingerprint, fp: remoteFp))]
    )

    waitFor recon.processRequest(request, context)
    check sentRanges.len > 1
    check sentRanges.anyIt(it.kind == RangeType.Fingerprint)
