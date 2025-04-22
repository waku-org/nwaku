import unittest
import ../../waku/waku_store_sync/storage/range_processing
import ../../waku/waku_store_sync/storage/seq_storage
import ../../waku/waku_store_sync/common
import ../../waku/waku_noise/noise_utils

suite "Waku Sync: Range Splitting and Skip Merging":

  test "split range when fingerprints mismatch":
    var storage = SeqStorage.new(@[])


    # Insert 8 messages across a timestamp range
    for i in 0 ..< 8:
      let id = SyncID(time: 1000 + i, hash: toDigest("msg" & $i))
      discard storage.insert(id)

    let fromId = SyncID(time: 1000, hash: toDigest("msg0"))
    let toId   = SyncID(time: 1008, hash: toDigest("msg7"))

    # Compute fingerprint of the full range
    let originalFp = storage.computeFingerprint(fromId .. toId)


    # Manually alter one item in a simulated remote store to force mismatch
    var alteredStorage = SeqStorage.new(@[])

    for i in 0 ..< 8:
      let hashSuffix = if i == 3: "MODIFIED" else: $i
      let id = SyncID(timestamp: 1000 + i, hash: toDigest("msg" & hashSuffix))
      discard alteredStorage.insert(id)

    let alteredFp = alteredStorage.computeFingerprint(fromId, toId)
    check originalFp != alteredFp

    # Expect subranges to be generated when mismatch occurs
    let subranges = splitRange(fromId, toId, depth = 2)
    check subranges.len == 4
