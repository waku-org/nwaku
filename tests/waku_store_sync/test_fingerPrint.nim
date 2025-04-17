import unittest
import chronicles
import ../../waku/waku_store_sync/common
import ../../waku/waku_store_sync/codec
import ../../waku/waku_store_sync/storage/seq_storage  
import ./sync_utils  

suite "Fingerprint-Based Range Comparison":

  test "Exact Match: fingerprints match for identical ItemSet":
    let items1 = randomItemSet(10)
    let items2 = items1  # identical copy

    var fp1, fp2: Fingerprint
    for id in items1.elements:
      fp1 = fp1 xor id.hash

    for id in items2.elements:
      fp2 = fp2 xor id.hash

    check fp1 == fp2
