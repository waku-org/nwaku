{.push raises: [].}

import
  chronos,
  chronicles,
  metrics,
  results,
  libp2p/protocols/ping,
  libp2p/builders,
  libp2p/transports/tcptransport

import ../../kernel, logos_delivery/kernel/node/peer_manager/peer_manager

logScope:
  topics = "waku node ping api"

proc mountLibp2pPing*(node: Kernel) {.async: (raises: []).} =
  info "mounting libp2p ping protocol"

  try:
    node.protocols.libp2pPing = Ping.new(rng = node.rng)
  except Exception as e:
    error "failed to create ping", error = getCurrentExceptionMsg()

  if node.started:
    # Node has started already. Let's start ping too.
    try:
      await node.protocols.libp2pPing.start()
    except CatchableError:
      error "failed to start libp2pPing", error = getCurrentExceptionMsg()

  try:
    node.switch.mount(node.protocols.libp2pPing)
  except LPError:
    error "failed to mount libp2pPing", error = getCurrentExceptionMsg()
