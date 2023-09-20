import
#   std/sequtils,
#   std/options,
#   stew/shims/net as stewNet,
#   testutils/unittests,
  chronicles,
  chronos
#   libp2p/crypto/crypto

import ../../../waku/waku_core/message

proc newPushHandlerFuture*(): Future[(string, WakuMessage)] =
    newFuture[(string, WakuMessage)]()
