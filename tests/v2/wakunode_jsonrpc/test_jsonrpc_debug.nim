{.used.}

import
  std/options,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  json_rpc/[rpcserver, rpcclient]
import
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/node/waku_node,
  ../../../waku/v2/node/jsonrpc/debug/handlers as debug_api,
  ../../../waku/v2/node/jsonrpc/debug/client as debug_api_client,
  ../testlib/waku2


procSuite "Waku v2 JSON-RPC API - Debug":
  let
    privkey = generateSecp256k1Key()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(0)
    node = WakuNode.new(privkey, bindIp, port, some(extIp), some(port))

  asyncTest "get node info":
    await node.start()

    await node.mountRelay()

    # RPC server setup
    let
      rpcPort = Port(8546)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installDebugApiHandlers(node, server)
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    let response = await client.get_waku_v2_debug_v1_info()

    check:
      response.listenAddresses == @[$node.switch.peerInfo.addrs[^1] & "/p2p/" & $node.switch.peerInfo.peerId]

    await server.stop()
    await server.closeWait()

    await node.stop()
