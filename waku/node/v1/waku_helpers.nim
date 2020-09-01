import
  chronos,
  eth/[p2p, async_utils], eth/p2p/peer_pool

proc setBootNodes*(nodes: openArray[string]): seq[ENode] =
  result = newSeqOfCap[ENode](nodes.len)
  for nodeId in nodes:
    # TODO: something more user friendly than an expect
    result.add(ENode.fromString(nodeId).expect("correct node"))

proc connectToNodes*(node: EthereumNode, nodes: openArray[string]) =
  for nodeId in nodes:
    # TODO: something more user friendly than an assert
    let whisperENode = ENode.fromString(nodeId).expect("correct node")

    traceAsyncErrors node.peerPool.connectToNode(newNode(whisperENode))
