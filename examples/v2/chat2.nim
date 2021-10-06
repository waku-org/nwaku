## chat2 is an example of usage of Waku v2. For suggested usage options, please
## see dingpu tutorial in docs folder.

when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

{.push raises: [Defect].}

import std/[tables, strformat, strutils, times, httpclient, json, sequtils, random, options]
import confutils, chronicles, chronos, stew/shims/net as stewNet,
       eth/keys, bearssl, stew/[byteutils, endians2, results],
       nimcrypto/pbkdf2
import libp2p/[switch,                   # manage transports, a single entry point for dialing and listening
               crypto/crypto,            # cryptographic functions
               stream/connection,        # create and close stream read / write connections
               multiaddress,             # encode different addressing schemes. For example, /ip4/7.7.7.7/tcp/6543 means it is using IPv4 protocol and TCP
               peerinfo,                 # manage the information of a peer, such as peer ID and public / private key
               peerid,                   # Implement how peers interact
               protobuf/minprotobuf,     # message serialisation/deserialisation from and to protobufs
               protocols/protocol,       # define the protocol base type
               protocols/secure/secio,   # define the protocol of secure input / output, allows encrypted communication that uses public keys to validate signed messages instead of a certificate authority like in TLS
               nameresolving/dnsresolver,# define DNS resolution
               muxers/muxer]             # define an interface for stream multiplexing, allowing peers to offer many protocols over a single connection
import   ../../waku/v2/node/[wakunode2, waku_payload],
         ../../waku/v2/node/./dnsdisc/waku_dnsdisc,
         ../../waku/v2/utils/peers,
         ../../waku/common/utils/nat,
         ./config_chat2

const Help = """
  Commands: /[?|help|connect|nick|exit]
  help: Prints this help
  connect: dials a remote peer
  nick: change nickname for current chat session
  exit: exits chat session
"""

const
  PayloadV1* {.booldefine.} = false
  DefaultTopic* = "/waku/2/default-waku/proto"

# XXX Connected is a bit annoying, because incoming connections don't trigger state change
# Could poll connection pool or something here, I suppose
# TODO Ensure connected turns true on incoming connections, or get rid of it
type Chat = ref object
    node: WakuNode          # waku node for publishing, subscribing, etc
    transp: StreamTransport # transport streams between read & write file descriptor
    subscribed: bool        # indicates if a node is subscribed or not to a topic
    connected: bool         # if the node is connected to another peer
    started: bool           # if the node has started
    nick: string            # nickname for this chat session
    prompt: bool            # chat prompt is showing
    contentTopic: string    # default content topic for chat messages
    symkey: SymKey          # SymKey used for v1 payload encryption (if enabled)

type
  PrivateKey* = crypto.PrivateKey
  Topic* = wakunode2.Topic

#####################
## chat2 protobufs ##
#####################

type
  SelectResult*[T] = Result[T, string]

  Chat2Message* = object
    timestamp*: int64
    nick*: string
    payload*: seq[byte]

proc init*(T: type Chat2Message, buffer: seq[byte]): ProtoResult[T] =
  var msg = Chat2Message()
  let pb = initProtoBuffer(buffer)

  var timestamp: uint64
  discard ? pb.getField(1, timestamp)
  msg.timestamp = int64(timestamp)

  discard ? pb.getField(2, msg.nick)
  discard ? pb.getField(3, msg.payload)

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

# Similarly as Status public chats now.
proc generateSymKey(contentTopic: ContentTopic): SymKey =
  var ctx: HMAC[sha256]
  var symKey: SymKey
  if pbkdf2(ctx, contentTopic.toBytes(), "", 65356, symKey) != sizeof(SymKey):
    raise (ref Defect)(msg: "Should not occur as array is properly sized")

  symKey

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

proc printReceivedMessage(c: Chat, msg: WakuMessage) =
  when PayloadV1:
      # Use Waku v1 payload encoding/encryption
      let
        keyInfo = KeyInfo(kind: Symmetric, symKey: c.symKey)
        decodedPayload = decodePayload(decoded.get(), keyInfo)

      if decodedPayload.isOK():
        let
          pb = Chat2Message.init(decodedPayload.get().payload)
          chatLine = if pb.isOk: pb[].toString()
                    else: string.fromBytes(decodedPayload.get().payload)
        echo &"{chatLine}"
        c.prompt = false
        showChatPrompt(c)
        trace "Printing message", topic=DefaultTopic, chatLine,
          contentTopic = msg.contentTopic
      else:
        debug "Invalid encoded WakuMessage payload",
          error = decodedPayload.error
  else:
    # No payload encoding/encryption from Waku
    let
      pb = Chat2Message.init(msg.payload)
      chatLine = if pb.isOk: pb[].toString()
                else: string.fromBytes(msg.payload)
    try:
      echo &"{chatLine}"
    except ValueError:
      # Formatting fail. Print chat line in any case.
      echo chatLine
    
    c.prompt = false
    showChatPrompt(c)
    trace "Printing message", topic=DefaultTopic, chatLine,
      contentTopic = msg.contentTopic

proc selectRandomNode(fleetStr: string): SelectResult[string] =
  randomize()
  var
    fleet: string
    nodes: seq[tuple[key: string, val: JsonNode]]
    randNode: string
  try:
    # Get latest fleet addresses
    fleet = newHttpClient().getContent("https://fleets.status.im")
  
    # Select the JSONObject corresponding to the selected wakuv2 fleet and convert to seq of key-val pairs
    nodes = toSeq(fleet.parseJson(){"fleets", "wakuv2." & fleetStr, "waku"}.pairs())
  
    if nodes.len < 1:
      return err("Empty fleet nodes list")

    # Select a random node from the selected fleet, convert to string and return
    randNode = nodes[rand(nodes.len - 1)].val.getStr()
  
  except Exception: # @TODO: HttpClient raises generic Exception
    return err("Failed to select random node")
  
  ok(randNode)

proc readNick(transp: StreamTransport): Future[string] {.async.} =
  # Chat prompt
  stdout.write("Choose a nickname >> ")
  stdout.flushFile()
  return await transp.readLine()

proc publish(c: Chat, line: string) =
  # First create a Chat2Message protobuf with this line of text
  let chat2pb = Chat2Message(timestamp: getTime().toUnix(),
                             nick: c.nick,
                             payload: line.toBytes()).encode()

  ## @TODO: error handling on failure
  proc handler(response: PushResponse) {.gcsafe, closure.} =
    trace "lightpush response received", response=response

  when PayloadV1:
    # Use Waku v1 payload encoding/encryption
    let
      payload = Payload(payload: chat2pb.buffer, symKey: some(c.symKey))
      version = 1'u32
      encodedPayload = payload.encode(version, c.node.rng[])
    if encodedPayload.isOk():
      let message = WakuMessage(payload: encodedPayload.get(),
        contentTopic: c.contentTopic, version: version)
      if not c.node.wakuLightPush.isNil():
        # Attempt lightpush
        asyncSpawn c.node.lightpush(DefaultTopic, message, handler)
      else:
        asyncSpawn c.node.publish(DefaultTopic, message, handler)
    else:
      warn "Payload encoding failed", error = encodedPayload.error
  else:
    # No payload encoding/encryption from Waku
    let message = WakuMessage(payload: chat2pb.buffer,
      contentTopic: c.contentTopic, version: 0)
    if not c.node.wakuLightPush.isNil():
      # Attempt lightpush
      asyncSpawn c.node.lightpush(DefaultTopic, message, handler)
    else:
      asyncSpawn c.node.publish(DefaultTopic, message)

# TODO This should read or be subscribe handler subscribe
proc readAndPrint(c: Chat) {.async.} =
  while true:
#    while p.connected:
#      # TODO: echo &"{p.id} -> "
#
#      echo cast[string](await p.conn.readLp(1024))
    #echo "readAndPrint subscribe NYI"
    await sleepAsync(100.millis)

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
      if not c.node.wakuFilter.isNil():
        echo "unsubscribing from content filters..."
      
        await c.node.unsubscribe(
          FilterRequest(contentFilters: @[ContentFilter(contentTopic: c.contentTopic)], pubSubTopic: DefaultTopic, subscribe: false)
        )
      
      echo "quitting..."

      await c.node.stop()

      quit(QuitSuccess)
    else:
      # XXX connected state problematic
      if c.started:
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

{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
proc processInput(rfd: AsyncFD, rng: ref BrHmacDrbgContext) {.async.} =
  let transp = fromPipe(rfd)

  let
    conf = Chat2Conf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.new(conf.nodekey, conf.listenAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)

  await node.start()

  node.mountRelay(conf.topics.split(" "),
                  relayMessages = conf.relay) # Indicates if node is capable to relay messages
  
  node.mountLibp2pPing()
  
  let nick = await readNick(transp)
  echo "Welcome, " & nick & "!"

  var chat = Chat(node: node,
                  transp: transp,
                  subscribed: true,
                  connected: false,
                  started: true,
                  nick: nick, 
                  prompt: false,
                  contentTopic: conf.contentTopic,
                  symKey: generateSymKey(conf.contentTopic))

  if conf.staticnodes.len > 0:
    await connectToNodes(chat, conf.staticnodes)
  elif conf.dnsDiscovery and conf.dnsDiscoveryUrl != "":
      # Discover nodes via DNS
      debug "Discovering nodes using Waku DNS discovery", url=conf.dnsDiscoveryUrl

      var nameServers: seq[TransportAddress]
      for ip in conf.dnsDiscoveryNameServers:
        nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

      let dnsResolver = DnsResolver.new(nameServers)

      proc resolver(domain: string): Future[string] {.async, gcsafe.} =
        trace "resolving", domain=domain
        let resolved = await dnsResolver.resolveTxt(domain)
        return resolved[0] # Use only first answer
      
      var wakuDnsDiscovery = WakuDnsDiscovery.init(conf.dnsDiscoveryUrl,
                                                   resolver)
      if wakuDnsDiscovery.isOk:
        let discoveredPeers = wakuDnsDiscovery.get().findPeers()
        if discoveredPeers.isOk:
          info "Connecting to discovered peers"
          waitFor chat.node.connectToNodes(discoveredPeers.get())
      else:
        warn "Failed to init Waku DNS discovery"
  elif conf.fleet != Fleet.none:
    # Connect to at least one random fleet node
    echo "No static peers configured. Choosing one at random from " & $conf.fleet & " fleet..."
    
    let randNode = selectRandomNode($conf.fleet)
    
    if randNode.isOk():
      echo "Connecting to " & randNode.get()

      await connectToNodes(chat, @[randNode.get()])
    else:
      echo "Couldn't select a random node to connect to. Check --fleet configuration."
      echo randNode.error()

  let peerInfo = node.peerInfo
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  echo &"Listening on\n {listenStr}"

  if conf.swap:
    node.mountSwap()

  if (conf.storenode != "") or (conf.store == true):
    node.mountStore(persistMessages = conf.persistMessages)

    var storenode: Option[string]

    if conf.storenode != "":
      storenode = some(conf.storenode)
    elif conf.fleet != Fleet.none:
      echo "Store enabled, but no store nodes configured. Choosing one at random from " & $conf.fleet & " fleet..."
      
      let selectNode = selectRandomNode($conf.fleet)

      if selectNode.isOk:
        storenode = some(selectNode.get())
      else:
        echo "Couldn't select a random store node to connect to. Check --fleet configuration."
        echo selectNode.error()
      
    if storenode.isSome():
      # We have a viable storenode. Let's query it for historical messages.
      echo "Connecting to storenode: " & storenode.get()

      node.wakuStore.setPeer(parseRemotePeerInfo(storenode.get()))

      proc storeHandler(response: HistoryResponse) {.gcsafe.} =
        for msg in response.messages:
          let
            pb = Chat2Message.init(msg.payload)
            chatLine = if pb.isOk: pb[].toString()
                      else: string.fromBytes(msg.payload)
          echo &"{chatLine}"
        info "Hit store handler"

      await node.query(HistoryQuery(contentFilters: @[HistoryContentFilter(contentTopic: chat.contentTopic)]), storeHandler)
  
  # NOTE Must be mounted after relay
  if conf.lightpushnode != "":
    mountLightPush(node)

    node.wakuLightPush.setPeer(parseRemotePeerInfo(conf.lightpushnode))

  if conf.filternode != "":
    node.mountFilter()

    node.wakuFilter.setPeer(parseRemotePeerInfo(conf.filternode))

    proc filterHandler(msg: WakuMessage) {.gcsafe.} =
      trace "Hit filter handler", contentTopic=msg.contentTopic

      chat.printReceivedMessage(msg)

    await node.subscribe(
      FilterRequest(contentFilters: @[ContentFilter(contentTopic: chat.contentTopic)], pubSubTopic: DefaultTopic, subscribe: true),
      filterHandler
    )

  # Subscribe to a topic, if relay is mounted
  if conf.relay:
    proc handler(topic: Topic, data: seq[byte]) {.async, gcsafe.} =
      trace "Hit subscribe handler", topic

      let decoded = WakuMessage.init(data)
      
      if decoded.isOk():
        chat.printReceivedMessage(decoded.get())
      else:
        trace "Invalid encoded WakuMessage", error = decoded.error

    let topic = cast[Topic](DefaultTopic)
    node.subscribe(topic, handler)

  await chat.readWriteLoop()

  if conf.keepAlive:
    node.startKeepalive()

  runForever()

proc main() {.async.} =
  let rng = crypto.newRng() # Singe random number source for the whole application
  let (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")

  var thread: Thread[AsyncFD]
  thread.createThread(readInput, wfd)

  await processInput(rfd, rng)

when isMainModule: # isMainModule = true when the module is compiled as the main file
  waitFor(main())

## Dump of things that can be improved:
##
## - Incoming dialed peer does not change connected state (not relying on it for now)
## - Unclear if staticnode argument works (can enter manually)
## - Don't trigger self / double publish own messages
## - Integrate store protocol (fetch messages in beginning)
## - Integrate filter protocol (default/option to be light node, connect to filter node)
## - Test/default to cluster node connection (diff protocol version)
## - Redirect logs to separate file
## - Expose basic publish/subscribe etc commands with /syntax
## - Show part of peerid to know who sent message
## - Deal with protobuf messages (e.g. other chat protocol, or encrypted)
