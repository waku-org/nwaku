import unittest, chronos, stew/byteutils, nimcrypto, std/sequtils
import ../../waku/waku_store_sync/[reconciliation, common]
import ../../waku/waku_store_sync/storage/seq_storage
import ../../waku/waku_core/message/digest
import ../testlib/assertions            

#  helpers 

proc toDigest*(s: string): WakuMessageHash =
  let d = nimcrypto.keccak256.digest((s & "").toOpenArrayByte(0, (s.len - 1)))
  for i in 0 .. 31:
    result[i] = d.data[i]

proc `..`(a, b: SyncID): Slice[SyncID] =
  Slice[SyncID](a: a, b: b)

template makeId(t, i: int): SyncID =
  SyncID(time: t, hash: toDigest("msg" & $i))

type Stats = ref object
  sent*: int
  fpSeen*: bool
  itemSetSeen*: bool
  parts*: seq[Slice[SyncID]]



suite "Waku Sync – reconciliation":

  test "splits mismatched fingerprint into two sub-ranges then item-set":

    let local  = SeqStorage.new(@[])
    let remote = SeqStorage.new(@[])

    for i in 0 ..< 8:
      discard local.insert(makeId(1000 + i, i))
      let t = if i == 3: 2000 + i else: 1000 + i   # single mismatch
      discard remote.insert(makeId(t, i))

    var z: WakuMessageHash                        # zero hash, only time matters
    let rng = SyncID(time: 1000, hash: z) .. SyncID(time: 1007, hash: z)
    check local.computeFingerprint(rng) != remote.computeFingerprint(rng)

    let stats = Stats()

    proc dummySend(p: RangesData) {.async, gcsafe.} =
      for (slc, kind) in p.ranges:
        inc stats.sent
        case kind
        of RangeType.Fingerprint:
          stats.fpSeen = true
          stats.parts.add slc
        of RangeType.ItemSet:
          stats.itemSetSeen = true
        else: discard

    let ctx = ReconciliationContext(
      driver:  local,        # SeqStorage already satisfies the driver interface
      sendFn:  dummySend,
      cluster: 0,
      shards:  @[0]
    )

    let recon = Reconciliation.new(local)

    let req: ReceivedPayload = (
      cluster: 0,
      shards: @[0],
      timestamp: 0'u64,
      ranges: @[(rng, RangeType.Fingerprint))
    )

    waitFor recon.processRequest(req, ctx)

    check stats.fpSeen
    check stats.itemSetSeen
    check stats.sent == 3
    check stats.parts.len == 2
    check stats.parts.anyIt(it.a.time == 1000 and it.b.time == 1003)
    check stats.parts.anyIt(it.a.time == 1004 and it.b.time == 1007)
