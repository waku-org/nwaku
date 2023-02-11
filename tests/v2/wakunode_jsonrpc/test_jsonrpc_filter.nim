{.used.}

import
  std/options,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  libp2p/crypto/crypto,
  json_rpc/[rpcserver, rpcclient]
import
  ../../../waku/v2/node/peer_manager,
  ../../../waku/v2/node/waku_node,
  ../../../waku/v2/node/message_cache,
  ../../../waku/v2/node/jsonrpc/filter/handlers as filter_api,
  ../../../waku/v2/node/jsonrpc/filter/client as filter_api_client,
  ../../../waku/v2/protocol/waku_message,
  ../../../waku/v2/protocol/waku_filter/rpc,
  ../../../waku/v2/protocol/waku_filter/client,
  ../../../waku/v2/utils/peers,
  ../testlib/waku2


proc newTestMessageCache(): filter_api.MessageCache =
  filter_api.MessageCache.init(capacity=30)


procSuite "Waku v2 JSON-RPC API - Filter":
  let
    bindIp = ValidIpAddress.init("0.0.0.0")

  asyncTest "subscribe and unsubscribe":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = WakuNode.new(nodeKey1, bindIp, Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = WakuNode.new(nodeKey2, bindIp, Port(0))

    await allFutures(node1.start(), node2.start())

    await node1.mountFilter()
    await node2.mountFilterClient()

    node2.setFilterPeer(node1.peerInfo.toRemotePeerInfo())

    # RPC server setup
    let
      rpcPort = Port(8550)
      ta = initTAddress(bindIp, rpcPort)
      server = newRpcHttpServer([ta])

    installFilterApiHandlers(node2, server, newTestMessageCache())
    server.start()

    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort, false)

    check:
      # Light node has not yet subscribed to any filters
      node2.wakuFilterClient.getSubscriptionsCount() == 0

    let contentFilters = @[
      ContentFilter(contentTopic: DefaultContentTopic),
      ContentFilter(contentTopic: ContentTopic("2")),
      ContentFilter(contentTopic: ContentTopic("3")),
      ContentFilter(contentTopic: ContentTopic("4")),
    ]
    var response = await client.post_waku_v2_filter_v1_subscription(contentFilters=contentFilters, topic=some(DefaultPubsubTopic))
    check:
      response == true
      # Light node has successfully subscribed to 4 content topics
      node2.wakuFilterClient.getSubscriptionsCount() == 4

    response = await client.delete_waku_v2_filter_v1_subscription(contentFilters=contentFilters, topic=some(DefaultPubsubTopic))
    check:
      response ==  true
      # Light node has successfully unsubscribed from all filters
      node2.wakuFilterClient.getSubscriptionsCount() == 0

    ## Cleanup
    await server.stop()
    await server.closeWait()

    await allFutures(node1.stop(), node2.stop())
