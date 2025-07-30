## chat2 is an example of usage of Waku v2. For suggested usage options, please
## see dingpu tutorial in docs folder.

when not (compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

{.push raises: [].}

import std/[strformat, strutils, times, options, random, sequtils]
import
  confutils,
  chronicles,
  chronos,
  eth/keys,
  bearssl,
  stew/[byteutils, results],
  metrics,
  metrics/chronos_httpserver
import
  libp2p/[
    switch, # manage transports, a single entry point for dialing and listening
    crypto/crypto, # cryptographic functions
    stream/connection, # create and close stream read / write connections
    multiaddress,
      # encode different addressing schemes. For example, /ip4/7.7.7.7/tcp/6543 means it is using IPv4 protocol and TCP
    peerinfo,
      # manage the information of a peer, such as peer ID and public / private key
    peerid, # Implement how peers interact
    protobuf/minprotobuf, # message serialisation/deserialisation from and to protobufs
    nameresolving/dnsresolver,
  ] # define DNS resolution
import mix/curve25519
import
  waku/[
    waku_core,
    waku_lightpush_legacy/common,
    waku_lightpush_legacy/rpc,
    waku_enr,
    discovery/waku_dnsdisc,
    waku_store_legacy,
    waku_node,
    node/waku_metrics,
    node/peer_manager,
    factory/builder,
    common/utils/nat,
    waku_relay,
    waku_store/common,
    waku_filter_v2/client,
  ],
  ./config_chat2mix

import libp2p/protocols/pubsub/rpc/messages, libp2p/protocols/pubsub/pubsub
import ../../waku/waku_rln_relay

logScope:
  topics = "chat2 mix"

const Help =
  """
  Commands: /[?|help|connect|nick|exit]
  help: Prints this help
  connect: dials a remote peer
  nick: change nickname for current chat session
  exit: exits chat session
"""

# XXX Connected is a bit annoying, because incoming connections don't trigger state change
# Could poll connection pool or something here, I suppose
# TODO Ensure connected turns true on incoming connections, or get rid of it
type Chat = ref object
  node: WakuNode # waku node for publishing, subscribing, etc
  transp: StreamTransport # transport streams between read & write file descriptor
  subscribed: bool # indicates if a node is subscribed or not to a topic
  connected: bool # if the node is connected to another peer
  started: bool # if the node has started
  nick: string # nickname for this chat session
  prompt: bool # chat prompt is showing
  contentTopic: string # default content topic for chat messages
  conf: Chat2Conf # configuration for chat2

type
  PrivateKey* = crypto.PrivateKey
  Topic* = waku_core.PubsubTopic

#####################
## chat2 protobufs ##
#####################

type
  SelectResult*[T] = Result[T, string]

  Chat2Message* = object
    timestamp*: int64
    nick*: string
    payload*: seq[byte]

proc getPubsubTopic*(
    conf: Chat2Conf, node: WakuNode, contentTopic: string
): PubsubTopic =
  let shard = node.wakuSharding.getShard(contentTopic).valueOr:
    echo "Could not parse content topic: " & error
    return "" #TODO: fix this.
  return $RelayShard(clusterId: conf.clusterId, shardId: shard.shardId)

proc init*(T: type Chat2Message, buffer: seq[byte]): ProtoResult[T] =
  var msg = Chat2Message()
  let pb = initProtoBuffer(buffer)

  var timestamp: uint64
  discard ?pb.getField(1, timestamp)
  msg.timestamp = int64(timestamp)

  discard ?pb.getField(2, msg.nick)
  discard ?pb.getField(3, msg.payload)

  ok(msg)

proc encode*(message: Chat2Message): ProtoBuffer =
  var serialised = initProtoBuffer()

  serialised.write(1, uint64(message.timestamp))
  serialised.write(2, message.nick)
  serialised.write(3, message.payload)

  return serialised

proc toString*(message: Chat2Message): string =
  # Get message date and timestamp in local time
  let time = message.timestamp.fromUnix().local().format("'<'MMM' 'dd,' 'HH:mm'>'")

  return time & " " & message.nick & ": " & string.fromBytes(message.payload)

#####################

proc connectToNodes(c: Chat, nodes: seq[string]) {.async.} =
  echo "Connecting to nodes"
  await c.node.connectToNodes(nodes)
  c.connected = true

proc showChatPrompt(c: Chat) =
  if not c.prompt:
    try:
      stdout.write(">> ")
      stdout.flushFile()
      c.prompt = true
    except IOError:
      discard

proc getChatLine(c: Chat, msg: WakuMessage): Result[string, string] =
  # No payload encoding/encryption from Waku
  let
    pb = Chat2Message.init(msg.payload)
    chatLine =
      if pb.isOk:
        pb[].toString()
      else:
        string.fromBytes(msg.payload)
  return ok(chatline)

proc printReceivedMessage(c: Chat, msg: WakuMessage) =
  let
    pb = Chat2Message.init(msg.payload)
    chatLine =
      if pb.isOk:
        pb[].toString()
      else:
        string.fromBytes(msg.payload)
  try:
    echo &"{chatLine}"
  except ValueError:
    # Formatting fail. Print chat line in any case.
    echo chatLine

  c.prompt = false
  showChatPrompt(c)
  trace "Printing message", chatLine, contentTopic = msg.contentTopic

proc readNick(transp: StreamTransport): Future[string] {.async.} =
  # Chat prompt
  stdout.write("Choose a nickname >> ")
  stdout.flushFile()
  return await transp.readLine()

proc startMetricsServer(
    serverIp: IpAddress, serverPort: Port
): Result[MetricsHttpServerRef, string] =
  info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $serverPort

  let metricsServerRes = MetricsHttpServerRef.new($serverIp, serverPort)
  if metricsServerRes.isErr():
    return err("metrics HTTP server start failed: " & $metricsServerRes.error)

  let server = metricsServerRes.value
  try:
    waitFor server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())

  info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $serverPort
  ok(metricsServerRes.value)

proc publish(c: Chat, line: string) =
  # First create a Chat2Message protobuf with this line of text
  let time = getTime().toUnix()
  let chat2pb =
    Chat2Message(timestamp: time, nick: c.nick, payload: line.toBytes()).encode()

  ## @TODO: error handling on failure
  proc handler(response: PushResponse) {.gcsafe, closure.} =
    trace "lightpush response received", response = response

  var message = WakuMessage(
    payload: chat2pb.buffer,
    contentTopic: c.contentTopic,
    version: 0,
    timestamp: getNanosecondTime(time),
  )

  try:
    if not c.node.wakuLightpushClient.isNil():
      # Attempt lightpush with mix
      #(
      discard c.node.lightpushPublish(
        some(c.conf.getPubsubTopic(c.node, c.contentTopic)),
        message,
        none(RemotePeerInfo),
        true,
      ) #TODO: Not waiting for response, have to change once SURB is implmented
      #).isOkOr:
      #  error "failed to publish lightpush message", error = error
    else:
      error "failed to publish message as lightpush client is not initialized"
  except CatchableError:
    error "caught error publishing message: ", error = getCurrentExceptionMsg()

# TODO This should read or be subscribe handler subscribe
proc readAndPrint(c: Chat) {.async.} =
  while true:
    #    while p.connected:
    #      # TODO: echo &"{p.id} -> "
    #
    #      echo cast[string](await p.conn.readLp(1024))
    #echo "readAndPrint subscribe NYI"
    await sleepAsync(100)

# TODO Implement
proc writeAndPrint(c: Chat) {.async.} =
  while true:
    # Connect state not updated on incoming WakuRelay connections
    #    if not c.connected:
    #      echo "type an address or wait for a connection:"
    #      echo "type /[help|?] for help"

    # Chat prompt
    showChatPrompt(c)

    let line = await c.transp.readLine()
    if line.startsWith("/help") or line.startsWith("/?") or not c.started:
      echo Help
      continue

    #    if line.startsWith("/disconnect"):
    #      echo "Ending current session"
    #      if p.connected and p.conn.closed.not:
    #        await p.conn.close()
    #      p.connected = false
    elif line.startsWith("/connect"):
      # TODO Should be able to connect to multiple peers for Waku chat
      if c.connected:
        echo "already connected to at least one peer"
        continue

      echo "enter address of remote peer"
      let address = await c.transp.readLine()
      if address.len > 0:
        await c.connectToNodes(@[address])
    elif line.startsWith("/nick"):
      # Set a new nickname
      c.nick = await readNick(c.transp)
      echo "You are now known as " & c.nick
    elif line.startsWith("/exit"):
      echo "quitting..."

      try:
        await c.node.stop()
      except:
        echo "exception happened when stopping: " & getCurrentExceptionMsg()

      quit(QuitSuccess)
    else:
      # XXX connected state problematic
      if c.started:
        echo "publishing message: " & line
        c.publish(line)
        # TODO Connect to peer logic?
      else:
        try:
          if line.startsWith("/") and "p2p" in line:
            await c.connectToNodes(@[line])
        except:
          echo &"unable to dial remote peer {line}"
          echo getCurrentExceptionMsg()

proc readWriteLoop(c: Chat) {.async.} =
  asyncSpawn c.writeAndPrint() # execute the async function but does not block
  asyncSpawn c.readAndPrint()

proc readInput(wfd: AsyncFD) {.thread, raises: [Defect, CatchableError].} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

var alreadyUsedServicePeers {.threadvar.}: seq[RemotePeerInfo]

proc selectRandomServicePeer*(
    pm: PeerManager, actualPeer: Option[RemotePeerInfo], codec: string
): Result[RemotePeerInfo, void] =
  if actualPeer.isSome():
    alreadyUsedServicePeers.add(actualPeer.get())

  let supportivePeers = pm.switch.peerStore.getPeersByProtocol(codec).filterIt(
      it notin alreadyUsedServicePeers
    )
  if supportivePeers.len == 0:
    return err()

  let rndPeerIndex = rand(0 .. supportivePeers.len - 1)
  return ok(supportivePeers[rndPeerIndex])

proc maintainSubscription(
    wakuNode: WakuNode,
    filterPubsubTopic: PubsubTopic,
    filterContentTopic: ContentTopic,
    filterPeer: RemotePeerInfo,
    preventPeerSwitch: bool,
) {.async.} =
  var actualFilterPeer = filterPeer
  const maxFailedSubscribes = 3
  const maxFailedServiceNodeSwitches = 10
  var noFailedSubscribes = 0
  var noFailedServiceNodeSwitches = 0
  while true:
    info "maintaining subscription at", peer = constructMultiaddrStr(actualFilterPeer)
    # First use filter-ping to check if we have an active subscription
    let pingRes = await wakuNode.wakuFilterClient.ping(actualFilterPeer)
    if pingRes.isErr():
      # No subscription found. Let's subscribe.
      error "ping failed.", err = pingRes.error
      trace "no subscription found. Sending subscribe request"

      let subscribeRes = await wakuNode.filterSubscribe(
        some(filterPubsubTopic), filterContentTopic, actualFilterPeer
      )

      if subscribeRes.isErr():
        noFailedSubscribes += 1
        error "Subscribe request failed.",
          err = subscribeRes.error,
          peer = actualFilterPeer,
          failCount = noFailedSubscribes

        # TODO: disconnet from failed actualFilterPeer
        # asyncSpawn(wakuNode.peerManager.switch.disconnect(p))
        # wakunode.peerManager.peerStore.delete(actualFilterPeer)

        if noFailedSubscribes < maxFailedSubscribes:
          await sleepAsync(2000) # Wait a bit before retrying
          continue
        elif not preventPeerSwitch:
          let peerOpt = selectRandomServicePeer(
            wakuNode.peerManager, some(actualFilterPeer), WakuFilterSubscribeCodec
          )
          if peerOpt.isOk():
            actualFilterPeer = peerOpt.get()

            info "Found new peer for codec",
              codec = filterPubsubTopic, peer = constructMultiaddrStr(actualFilterPeer)

            noFailedSubscribes = 0
            continue # try again with new peer without delay
          else:
            error "Failed to find new service peer. Exiting."
            noFailedServiceNodeSwitches += 1
            break
      else:
        if noFailedSubscribes > 0:
          noFailedSubscribes -= 1

        notice "subscribe request successful."
    else:
      info "subscription is live."

    await sleepAsync(30000) # Subscription maintenance interval

proc processMixNodes(localnode: WakuNode, nodes: seq[string]) {.async.} =
  if nodes.len == 0:
    return

  echo "Processing mix nodes: ", $nodes
  for node in nodes:
    var enrRec: enr.Record
    if enrRec.fromURI(node):
      let peerInfo = enrRec.toRemotePeerInfo().valueOr:
        error "Failed to parse mix node", error = error
        continue
      localnode.peermanager.addPeer(peerInfo, Discv5)
      info "Added mix node", peer = peerInfo
    else:
      error "Failed to parse mix node ENR", node = node

{.pop.}
  # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
proc processInput(rfd: AsyncFD, rng: ref HmacDrbgContext) {.async.} =
  let
    transp = fromPipe(rfd)
    conf = Chat2Conf.load()
    nodekey =
      if conf.nodekey.isSome():
        conf.nodekey.get()
      else:
        PrivateKey.random(Secp256k1, rng[]).tryGet()

  # set log level
  if conf.logLevel != LogLevel.NONE:
    setLogLevel(conf.logLevel)

  let natRes = setupNat(
    conf.nat,
    clientId,
    Port(uint16(conf.tcpPort) + conf.portsShift),
    Port(uint16(conf.udpPort) + conf.portsShift),
  )

  if natRes.isErr():
    raise newException(ValueError, "setupNat error " & natRes.error)

  let (extIp, extTcpPort, extUdpPort) = natRes.get()

  var enrBuilder = EnrBuilder.init(nodeKey)

  enrBuilder.withWakuRelaySharding(
    RelayShards(clusterId: conf.clusterId, shardIds: conf.shards)
  ).isOkOr:
    error "failed to add sharded topics to ENR", error = error
    quit(QuitFailure)

  let recordRes = enrBuilder.build()
  let record =
    if recordRes.isErr():
      error "failed to create enr record", error = recordRes.error
      quit(QuitFailure)
    else:
      recordRes.get()

  let node = block:
    var builder = WakuNodeBuilder.init()
    builder.withNodeKey(nodeKey)
    builder.withRecord(record)

    builder
    .withNetworkConfigurationDetails(
      conf.listenAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      extIp,
      extTcpPort,
      wsBindPort = Port(uint16(conf.websocketPort) + conf.portsShift),
      wsEnabled = conf.websocketSupport,
      wssEnabled = conf.websocketSecureSupport,
    )
    .tryGet()
    builder.build().tryGet()

  node.mountSharding(conf.clusterId, conf.numShardsInNetwork).isOkOr:
    error "failed to mount waku sharding: ", error = error
    quit(QuitFailure)
  node.mountMetadata(conf.clusterId).isOkOr:
    error "failed to mount waku metadata protocol: ", err = error
    quit(QuitFailure)

  try:
    await node.mountPeerExchange()
  except CatchableError:
    error "failed to mount waku peer-exchange protocol",
      error = getCurrentExceptionMsg()
    quit(QuitFailure)

  let (mixPrivKey, mixPubKey) = generateKeyPair().valueOr:
    error "failed to generate mix key pair", error = error
    return

  (await node.mountMix(conf.clusterId, mixPrivKey)).isOkOr:
    error "failed to mount waku mix protocol: ", error = $error
    quit(QuitFailure)
  if conf.mixnodes.len > 0:
    await processMixNodes(node, conf.mixnodes)
  await node.start()

  node.peerManager.start()

  #[   if conf.rlnRelayCredPath == "":
    raise newException(ConfigurationError, "rln-relay-cred-path MUST be passed")

  if conf.relay:
    let shards =
      conf.shards.mapIt(RelayShard(clusterId: conf.clusterId, shardId: uint16(it)))
    (await node.mountRelay()).isOkOr:
      echo "failed to mount relay: " & error
      return
      ]#
  await node.mountLibp2pPing()
  let pubsubTopic = conf.getPubsubTopic(node, conf.contentTopic)
  echo "pubsub topic is: " & pubsubTopic
  let nick = await readNick(transp)
  echo "Welcome, " & nick & "!"

  var chat = Chat(
    node: node,
    transp: transp,
    subscribed: true,
    connected: false,
    started: true,
    nick: nick,
    prompt: false,
    contentTopic: conf.contentTopic,
    conf: conf,
  )

  var dnsDiscoveryUrl = none(string)

  if conf.fleet != Fleet.none:
    # Use DNS discovery to connect to selected fleet
    echo "Connecting to " & $conf.fleet & " fleet using DNS discovery..."

    if conf.fleet == Fleet.test:
      dnsDiscoveryUrl = some(
        "enrtree://AOGYWMBYOUIMOENHXCHILPKY3ZRFEULMFI4DOM442QSZ73TT2A7VI@test.waku.nodes.status.im"
      )
    else:
      # Connect to sandbox by default
      dnsDiscoveryUrl = some(
        "enrtree://AIRVQ5DDA4FFWLRBCHJWUWOO6X6S4ZTZ5B667LQ6AJU6PEYDLRD5O@sandbox.waku.nodes.status.im"
      )
  elif conf.dnsDiscoveryUrl != "":
    # No pre-selected fleet. Discover nodes via DNS using user config
    debug "Discovering nodes using Waku DNS discovery", url = conf.dnsDiscoveryUrl
    dnsDiscoveryUrl = some(conf.dnsDiscoveryUrl)

  var discoveredNodes: seq[RemotePeerInfo]

  if dnsDiscoveryUrl.isSome:
    var nameServers: seq[TransportAddress]
    for ip in conf.dnsDiscoveryNameServers:
      nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

    let dnsResolver = DnsResolver.new(nameServers)

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      trace "resolving", domain = domain
      let resolved = await dnsResolver.resolveTxt(domain)
      return resolved[0] # Use only first answer

    var wakuDnsDiscovery = WakuDnsDiscovery.init(dnsDiscoveryUrl.get(), resolver)
    if wakuDnsDiscovery.isOk:
      let discoveredPeers = await wakuDnsDiscovery.get().findPeers()
      if discoveredPeers.isOk:
        info "Connecting to discovered peers"
        discoveredNodes = discoveredPeers.get()
        echo "Discovered and connecting to " & $discoveredNodes
        waitFor chat.node.connectToNodes(discoveredNodes)
    else:
      warn "Failed to init Waku DNS discovery"

  let peerInfo = node.switch.peerInfo
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  echo &"Listening on\n {listenStr}"

  if (conf.storenode != "") or (conf.store == true):
    await node.mountStore()

    var storenode: Option[RemotePeerInfo]

    if conf.storenode != "":
      let peerInfo = parsePeerInfo(conf.storenode)
      if peerInfo.isOk():
        storenode = some(peerInfo.value)
      else:
        error "Incorrect conf.storenode", error = peerInfo.error
    elif discoveredNodes.len > 0:
      echo "Store enabled, but no store nodes configured. Choosing one at random from discovered peers"
      storenode = some(discoveredNodes[rand(0 .. len(discoveredNodes) - 1)])

    if storenode.isSome():
      # We have a viable storenode. Let's query it for historical messages.
      echo "Connecting to storenode: " & $(storenode.get())

      node.mountStoreClient()
      node.peerManager.addServicePeer(storenode.get(), WakuStoreCodec)

      proc storeHandler(response: StoreQueryResponse) {.gcsafe.} =
        for msg in response.messages:
          let payload =
            if msg.message.isSome():
              msg.message.get().payload
            else:
              newSeq[byte](0)

          let
            pb = Chat2Message.init(payload)
            chatLine =
              if pb.isOk:
                pb[].toString()
              else:
                string.fromBytes(payload)
          echo &"{chatLine}"
        info "Hit store handler"

      let queryRes = await node.query(
        StoreQueryRequest(contentTopics: @[chat.contentTopic]), storenode.get()
      )
      if queryRes.isOk():
        storeHandler(queryRes.value)

  if conf.edgemode: #Mount light protocol clients
    node.mountLightPushClient()
    await node.mountFilterClient()
    let filterHandler = proc(
        pubsubTopic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, closure.} =
      trace "Hit filter handler", contentTopic = msg.contentTopic
      chat.printReceivedMessage(msg)

    node.wakuFilterClient.registerPushHandler(filterHandler)

  if conf.serviceNode != "": #TODO: use one of discovered nodes if not present.  
    let peerInfo = parsePeerInfo(conf.serviceNode)
    if peerInfo.isOk():
      #await mountLegacyLightPush(node)
      node.peerManager.addServicePeer(peerInfo.value, WakuLightpushCodec)
      node.peerManager.addServicePeer(peerInfo.value, WakuPeerExchangeCodec)
      # Start maintaining subscription
      asyncSpawn maintainSubscription(
        node, pubsubTopic, conf.contentTopic, peerInfo.value, false
      )
    else:
      error "LightPushClient not mounted. Couldn't parse conf.serviceNode",
        error = peerInfo.error
  # TODO: Loop faster
  node.startPeerExchangeLoop()

  while node.getMixNodePoolSize() < 3:
    info "waiting for mix nodes to be discovered",
      currentpoolSize = node.getMixNodePoolSize()
    await sleepAsync(1000)
  notice "ready to publish with mix node pool size ",
    currentpoolSize = node.getMixNodePoolSize()
  echo "ready to publish messages now"
  # Subscribe to a topic, if relay is mounted
  #[  if conf.relay:
    proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
      trace "Hit subscribe handler", topic

      if msg.contentTopic == chat.contentTopic:
        chat.printReceivedMessage(msg)

    node.subscribe((kind: PubsubSub, topic: pubsubTopic), WakuRelayHandler(handler)).isOkOr:
      error "failed to subscribe to pubsub topic", topic = pubsubTopic, error = error ]#

  #[    if conf.rlnRelay:
      info "WakuRLNRelay is enabled"

      proc spamHandler(wakuMessage: WakuMessage) {.gcsafe, closure.} =
        debug "spam handler is called"
        let chatLineResult = chat.getChatLine(wakuMessage)
        if chatLineResult.isOk():
          echo "A spam message is found and discarded : ", chatLineResult.value
        else:
          echo "A spam message is found and discarded"
        chat.prompt = false
        showChatPrompt(chat)

      echo "rln-relay preparation is in progress..."

      let rlnConf = WakuRlnConfig(
        dynamic: conf.rlnRelayDynamic,
        credIndex: conf.rlnRelayCredIndex,
        chainId: UInt256.fromBytesBE(conf.rlnRelayChainId.toBytesBE()),
        ethClientUrls: conf.ethClientUrls.mapIt(string(it)),
        creds: some(
          RlnRelayCreds(
            path: conf.rlnRelayCredPath, password: conf.rlnRelayCredPassword
          )
        ),
        userMessageLimit: conf.rlnRelayUserMessageLimit,
        epochSizeSec: conf.rlnEpochSizeSec,
        treePath: conf.rlnRelayTreePath,
      )

      waitFor node.mountRlnRelay(rlnConf, spamHandler = some(spamHandler))

      let membershipIndex = node.wakuRlnRelay.groupManager.membershipIndex.get()
      let identityCredential = node.wakuRlnRelay.groupManager.idCredentials.get()
      echo "your membership index is: ", membershipIndex
      echo "your rln identity commitment key is: ",
        identityCredential.idCommitment.inHex()
    else:
      info "WakuRLNRelay is disabled"
      echo "WakuRLNRelay is disabled, please enable it by passing in the --rln-relay flag" ]#
  if conf.metricsLogging:
    startMetricsLog()

  if conf.metricsServer:
    let metricsServer = startMetricsServer(
      conf.metricsServerAddress, Port(conf.metricsServerPort + conf.portsShift)
    )

  await chat.readWriteLoop()

  runForever()

proc main(rng: ref HmacDrbgContext) {.async.} =
  let (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")

  var thread: Thread[AsyncFD]
  thread.createThread(readInput, wfd)
  try:
    await processInput(rfd, rng)
  # Handle only ConfigurationError for now
  # TODO: Throw other errors from the mounting procedure
  except ConfigurationError as e:
    raise e

when isMainModule: # isMainModule = true when the module is compiled as the main file
  let rng = crypto.newRng()
  try:
    waitFor(main(rng))
  except CatchableError as e:
    raise e

## Dump of things that can be improved:
##
## - Incoming dialed peer does not change connected state (not relying on it for now)
## - Unclear if staticnode argument works (can enter manually)
## - Don't trigger self / double publish own messages
## - Test/default to cluster node connection (diff protocol version)
## - Redirect logs to separate file
## - Expose basic publish/subscribe etc commands with /syntax
## - Show part of peerid to know who sent message
## - Deal with protobuf messages (e.g. other chat protocol, or encrypted)
