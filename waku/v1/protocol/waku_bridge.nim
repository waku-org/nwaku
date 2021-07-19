#
#             Waku - Whisper Bridge
#              (c) Copyright 2018-2021
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)
#

{.push raises: [Defect].}

import
  eth/p2p,
  #eth/p2p/rlpx_protocols/whisper_protocol,
  ../../whisper/whisper_protocol,
  ./waku_protocol

proc shareMessageQueue*(node: EthereumNode) =
  node.protocolState(Waku).queue = node.protocolState(Whisper).queue
