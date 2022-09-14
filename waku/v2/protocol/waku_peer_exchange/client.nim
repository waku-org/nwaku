{.push raises: [Defect].}

import 
  std/[tables, sequtils],
  chronicles
import
  ../waku_message,
  ./rpc

proc storePeerInfo*(enrs: seq[byte]) =
  # TODO this function will store Info provided by the responder
  return

