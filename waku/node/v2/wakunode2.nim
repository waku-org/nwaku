import
  std/[strutils, options, tables],
  chronos, confutils, json_rpc/rpcserver, metrics, stew/shims/net as stewNet,
  # TODO: Why do we need eth keys?
  eth/keys,
  # eth/[keys, p2p], eth/net/nat, eth/p2p/[discovery, enode],
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  # NOTE For TopicHandler, solve with exports?
  libp2p/protocols/pubsub/pubsub,
  libp2p/peerinfo,
  standard_setup,
  ../../protocol/v2/[waku_relay, waku_store, waku_filter], ../common,
  ./waku_types, ./config, ./standard_setup

# key and crypto modules different
type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

  # TODO Get rid of this and use waku_types one
  Topic* = waku_types.Topic
  Message* = seq[byte]

  HistoryQuery* = object
    topics*: seq[string]

  HistoryResponse* = object
    messages*: seq[Message]

const clientId* = "Nimbus Waku v2 node"

template tcpEndPoint(address, port): auto =
  MultiAddress.init(address, tcpProtocol, port)

## Public API
##

proc init*(T: type WakuNode, nodeKey: crypto.PrivateKey,
    bindIp: ValidIpAddress, bindPort: Port,
    extIp = none[ValidIpAddress](), extPort = none[Port]()): T =
  ## Creates and starts a Waku node.
  let
    hostAddress = tcpEndPoint(bindIp, bindPort)
    announcedAddresses = if extIp.isNone() or extPort.isNone(): @[]
                         else: @[tcpEndPoint(extIp.get(), extPort.get())]
    peerInfo = PeerInfo.init(nodekey)
  info "Initializing networking", hostAddress,
                                  announcedAddresses
  # XXX: Add this when we create node or start it?
  peerInfo.addrs.add(hostAddress)

  var switch = newStandardSwitch(some(nodekey), hostAddress, triggerSelf = true)

  return WakuNode(switch: switch, peerInfo: peerInfo)

proc start*(node: WakuNode) {.async.} =
  node.libp2pTransportLoops = await node.switch.start()

  # NOTE WakuRelay is being instantiated as part of creating switch with PubSub field set
  let storeProto = WakuStore.init()
  node.switch.mount(storeProto)

  let filterProto = WakuFilter.init()
  node.switch.mount(filterProto)

  # TODO Get this from WakuNode obj
  let peerInfo = node.peerInfo
  let id = peerInfo.peerId.pretty
  info "PeerInfo", id = id, addrs = peerInfo.addrs
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & id
  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr

proc stop*(node: WakuNode) {.async.} =
  let wakuRelay = node.switch.pubSub.get()
  await wakuRelay.stop()

  await node.switch.stop()

proc subscribe*(w: WakuNode, topic: Topic, handler: TopicHandler) =
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and some data.
  ##
  ## NOTE The data field SHOULD be decoded as a WakuMessage.
  ## Status: Implemented.

  let wakuRelay = w.switch.pubSub.get()
  # XXX Consider awaiting here
  discard wakuRelay.subscribe(topic, handler)

proc subscribe*(w: WakuNode, contentFilter: waku_types.ContentFilter, handler: ContentFilterHandler) =
  ## Subscribes to a ContentFilter. Triggers handler when receiving messages on
  ## this content filter. ContentFilter is a method that takes some content
  ## filter, specifically with `ContentTopic`, and a `Message`. The `Message`
  ## has to match the `ContentTopic`.

  # TODO: get some random id, or use the Filter directly as key
  w.filters.add("some random id", Filter(contentFilter: contentFilter, handler: handler))

proc unsubscribe*(w: WakuNode, topic: Topic) =
  echo "NYI"
  ## Unsubscribe from a topic.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.

proc unsubscribe*(w: WakuNode, contentFilter: waku_types.ContentFilter) =
  echo "NYI"
  ## Unsubscribe from a content filter.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.


proc publish*(node: WakuNode, topic: Topic, message: WakuMessage) =
  ## Publish a `WakuMessage` to a PubSub topic. `WakuMessage` should contain a
  ## `contentTopic` field for light node functionality. This field may be also
  ## be omitted.
  ##
  ## Status: Implemented.
  ##

  # TODO Basic getter function for relay
  let wakuRelay = cast[WakuRelay](node.switch.pubSub.get())

  # XXX Unclear what the purpose of this is
  # Commenting out as it is later expected to be Message type, not WakuMessage
  #node.messages.insert((topic, message))

  debug "publish", topic=topic, contentTopic=message.contentTopic
  let data = message.encode().buffer

  # XXX Consider awaiting here
  discard wakuRelay.publish(topic, data)

proc query*(w: WakuNode, query: HistoryQuery): HistoryResponse =
  ## Queries for historical messages.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_store` and send RPC.
  result.messages = newSeq[Message]()

  for msg in w.messages:
    if msg[0] notin query.topics:
      continue

    # XXX Unclear how this should be hooked up, Message or WakuMessage?
    # result.messages.insert(msg[1])
