import unittest, chronos, stew/byteutils, nimcrypto, std/sequtils
import ../../waku/waku_store_sync/[reconciliation, common]
import ../../waku/waku_store_sync/storage/seq_storage
import ../../waku/waku_core/message/digest
import ../testlib/assertions
import std/algorithm

# ---------- helpers ----------

proc toDigest*(s: string): WakuMessageHash =
  let d = nimcrypto.keccak256.digest((s & "").toOpenArrayByte(0, (s.len - 1)))
  for i in 0 .. 31: result[i] = d.data[i]

proc `..`(a, b: SyncID): Slice[SyncID] =
  Slice[SyncID](a: a, b: b)

template makeId(t, i: int): SyncID =
  SyncID(time: t, hash: toDigest("msg" & $i))

#test

suite "Waku Sync – reconciliation":

  test "splits mismatched fingerprint into two sub-ranges then item-set":

    let local  = SeqStorage.new(@[])
    let remote = SeqStorage.new(@[])
    var mismatchHash: WakuMessageHash
    var remoteHash:  WakuMessageHash
    
    for i in 0 ..< 8:
      let baseTime = 1000 + i
      let baseHash = toDigest("msg" & $i)
      let idLocal = SyncID(time: baseTime, hash: baseHash)
      discard local.insert(idLocal)
      if i == 3: 
        remoteHash=toDigest("msg" & $i & "_x")   
        mismatchHash = remoteHash
      else:      
        remoteHash=baseHash

      let idRemote = SyncID(time: baseTime, hash: remoteHash)
      discard remote.insert(idRemote)

    var z: WakuMessageHash
    let whole = SyncID(time: 1000, hash: z) .. SyncID(time: 1007, hash: z)

    let remoteFp = remote.computeFingerprint(whole)
    let payload  = RangesData(
      cluster: 0,
      shards:  @[0],
      ranges:  @[(whole, RangeType.Fingerprint)],
      fingerprints: @[remoteFp],
      itemSets: @[]
    )

    var toSend: seq[WakuMessageHash]
    var toRecv: seq[WakuMessageHash]

    let reply = local.processPayload(payload, toSend, toRecv)

    let ranges = reply.ranges
    check ranges.len == 1
    check ranges[0][1] == RangeType.ItemSet
    check reply.itemSets.len == 1                      

    let iset = reply.itemSets[0]
    let idx = iset.elements.find(proc (x: SyncID): bool = x.hash == mismatchHash)
    check idx != -1                                   
    let bad = iset.elements[idx]
    check bad.time == 1000 + 3

   
