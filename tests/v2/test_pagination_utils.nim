{.used.}

import
  testutils/unittests,
  chronos,
  stew/byteutils,
  libp2p/crypto/crypto,
  ../../waku/v2/utils/pagination,
  ../../waku/v2/utils/time

procSuite "Pagination utils":

  ## Helpers
  proc hashFromStr(input: string): MDigest[256] =
    var ctx: sha256
    
    ctx.init()
    ctx.update(input.toBytes()) # converts the input to bytes
    
    let hashed = ctx.finish() # computes the hash
    ctx.clear()

    return hashed

  ## Test vars
  let
    smallIndex1 = Index(digest: hashFromStr("1234"),
                        receiverTime: getNanosecondTime(0),
                        senderTime: getNanosecondTime(1000))
    smallIndex2 = Index(digest: hashFromStr("1234567"), # digest is less significant than senderTime
                        receiverTime: getNanosecondTime(0),
                        senderTime: getNanosecondTime(1000))
    largeIndex1 = Index(digest: hashFromStr("1234"),
                        receiverTime: getNanosecondTime(0),
                        senderTime: getNanosecondTime(9000)) # only senderTime differ from smallIndex1
    largeIndex2 = Index(digest: hashFromStr("12345"), # only digest differs from smallIndex1
                        receiverTime: getNanosecondTime(0),
                        senderTime: getNanosecondTime(1000))
    eqIndex1 = Index(digest: hashFromStr("0003"),
                     receiverTime: getNanosecondTime(0),
                     senderTime: getNanosecondTime(54321))
    eqIndex2 = Index(digest: hashFromStr("0003"),
                     receiverTime: getNanosecondTime(0),
                     senderTime: getNanosecondTime(54321))
    eqIndex3 = Index(digest: hashFromStr("0003"),
                     receiverTime: getNanosecondTime(9999), # receiverTime difference should have no effect on comparisons
                     senderTime: getNanosecondTime(54321))
                      

  ## Test suite
  asyncTest "Index comparison":
    check:
      # Index comparison with senderTime diff
      cmp(smallIndex1, largeIndex1) < 0
      cmp(smallIndex2, largeIndex1) < 0

      # Index comparison with digest diff
      cmp(smallIndex1, smallIndex2) < 0
      cmp(smallIndex1, largeIndex2) < 0
      cmp(smallIndex2, largeIndex2) > 0
      cmp(largeIndex1, largeIndex2) > 0

      # Index comparison when equal
      cmp(eqIndex1, eqIndex2) == 0

      # receiverTime difference play no role
      cmp(eqIndex1, eqIndex3) == 0

  asyncTest "Index equality":
    check:
      # Exactly equal
      eqIndex1 == eqIndex2

      # Receiver time plays no role
      eqIndex1 == eqIndex3

      # Unequal sender time
      smallIndex1 != largeIndex1

      # Unequal digest
      smallIndex1 != smallIndex2

      # Unequal hash and digest
      smallIndex1 != eqIndex1
