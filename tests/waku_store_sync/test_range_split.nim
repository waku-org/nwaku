import unittest, nimcrypto, std/sequtils
import ../../waku/waku_store_sync/[reconciliation, common]
import ../../waku/waku_store_sync/storage/seq_storage
import ../../waku/waku_core/message/digest

proc toDigest*(s: string): WakuMessageHash =
  let d = nimcrypto.keccak256.digest((s & "").toOpenArrayByte(0, (s.len - 1)))
  for i in 0 .. 31: result[i] = d.data[i]

proc `..`(a, b: SyncID): Slice[SyncID] =
  Slice[SyncID](a: a, b: b)

suite "Waku Sync – reconciliation":

  test "fan-out: eight fingerprint sub-ranges for large slice":

    const N         = 2_048
    const mismatchI = 70

    let local  = SeqStorage.new(@[])
    let remote = SeqStorage.new(@[])

    var baseHashMismatch:   WakuMessageHash
    var remoteHashMismatch: WakuMessageHash

    for i in 0 ..< N:
      let ts        = 1000 + i
      let hashLocal = toDigest("msg" & $i)
      discard local.insert(SyncID(time: ts, hash: hashLocal))

      var hashRemote = hashLocal
      if i == mismatchI:
        baseHashMismatch   = hashLocal
        remoteHashMismatch = toDigest("msg" & $i & "_x")
        hashRemote         = remoteHashMismatch
      discard remote.insert(SyncID(time: ts, hash: hashRemote))

    var z: WakuMessageHash
    let whole = SyncID(time: 1000, hash: z) .. SyncID(time: 1000 + N - 1, hash: z)

    check local.computeFingerprint(whole) != remote.computeFingerprint(whole)

    let remoteFp = remote.computeFingerprint(whole)
    let payload  = RangesData(
      cluster:      0,
      shards:       @[0],
      ranges:       @[(whole, RangeType.Fingerprint)],
      fingerprints: @[remoteFp],
      itemSets:     @[]
    )

    var toSend, toRecv: seq[WakuMessageHash]
    let reply = local.processPayload(payload, toSend, toRecv)

    check reply.ranges.len == 8
    check reply.ranges.allIt(it[1] == RangeType.Fingerprint)
    check reply.itemSets.len == 0
    check reply.fingerprints.len == 8

    let mismTime = 1000 + mismatchI
    var covered = false
    for (slc, _) in reply.ranges:
      if mismTime >= slc.a.time and mismTime <= slc.b.time:
        covered = true
        break
    check covered

    check toSend.len == 0
    check toRecv.len == 0
