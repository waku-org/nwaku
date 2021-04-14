## chat2 is an example of usage of Waku v2. For suggested usage options, please
## see dingpu tutorial in docs folder.

when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

import std/[tables, strformat, strutils, times, httpclient, json, sequtils, random]
import confutils, chronicles, chronos, stew/shims/net as stewNet,
       eth/keys, bearssl, stew/[byteutils, endians2],
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
               muxers/muxer]             # define an interface for stream multiplexing, allowing peers to offer many protocols over a single connection
import   ../../waku/v2/node/[config, wakunode2, waku_payload],
         ../../waku/v2/protocol/waku_message,
         ../../waku/v2/protocol/waku_store/waku_store,
         ../../waku/v2/protocol/waku_filter/waku_filter,
         ../../waku/v2/utils/peers,
         ../../waku/common/utils/nat

const Help = """
  Commands: /[?|help|connect|nick]
  help: Prints this help
  connect: dials a remote peer
  nick: change nickname for current chat session
  exit: exits chat session
"""

const
  PayloadV1* {.booldefine.} = false
  DefaultTopic = "/waku/2/default-waku/proto"

  DefaultContentTopic = ContentTopic("dingpu")

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

type
  PrivateKey* = crypto.PrivateKey
  Topic* = wakunode2.Topic

#####################
## chat2 protobufs ##
#####################

type Chat2Message* = object
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

let DefaultSymKey = generateSymKey(DefaultContentTopic)

proc connectToNodes(c: Chat, nodes: seq[string]) {.async.} =
  echo "Connecting to nodes"
  await c.node.connectToNodes(nodes)
  c.connected = true

proc showChatPrompt(c: Chat) =
  if not c.prompt:
    stdout.write(">> ")
    stdout.flushFile()
    c.prompt = true

proc selectRandomNode(): string =
  randomize()
  let
    # Get latest fleet
    fleet = newHttpClient().getContent("https://fleets.status.im")
    # Select the JSONObject corresponding to the wakuv2 test fleet and convert to seq of key-val pairs
    nodes = toSeq(fleet.parseJson(){"fleets", "wakuv2.test", "waku"}.pairs())
    
  # Select a random node from the test fleet, convert to string and return
  return nodes[rand(nodes.len - 1)].val.getStr()

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

  when PayloadV1:
    # Use Waku v1 payload encoding/encryption
    let
      payload = Payload(payload: chat2pb.buffer, symKey: some(DefaultSymKey))
      version = 1'u32
      encodedPayload = payload.encode(version, c.node.rng[])
    if encodedPayload.isOk():
      let message = WakuMessage(payload: encodedPayload.get(),
        contentTopic: DefaultContentTopic, version: version)
      asyncSpawn c.node.publish(DefaultTopic, message)
    else:
      warn "Payload encoding failed", error = encodedPayload.error
  else:
    # No payload encoding/encryption from Waku
    let message = WakuMessage(payload: chat2pb.buffer,
      contentTopic: DefaultContentTopic, version: 0)
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
     await c.node.stop()

     echo "quitting..."
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
  asyncCheck c.writeAndPrint() # execute the async function but does not block
  asyncCheck c.readAndPrint()

proc readInput(wfd: AsyncFD) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

proc processInput(rfd: AsyncFD, rng: ref BrHmacDrbgContext) {.async.} =
  let transp = fromPipe(rfd)

  let
    conf = WakuNodeConf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.init(conf.nodeKey, conf.listenAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)

  await node.start()

  if conf.filternode != "":
    node.mountRelay(conf.topics.split(" "), rlnRelayEnabled = conf.rlnrelay)
  else:
    node.mountRelay(@[], rlnRelayEnabled = conf.rlnrelay)
  
  let nick = await readNick(transp)
  echo "Welcome, " & nick & "!"

  var chat = Chat(node: node, transp: transp, subscribed: true, connected: false, started: true, nick: nick, prompt: false)

  if conf.staticnodes.len > 0:
    await connectToNodes(chat, conf.staticnodes)
  else:
    # Connect to at least one random fleet node
    echo "No static peers configured. Choosing one at random from test fleet..."
    
    let randNode = selectRandomNode()
    
    echo "Connecting to " & randNode

    await connectToNodes(chat, @[randNode])

  let peerInfo = node.peerInfo
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  echo &"Listening on\n {listenStr}"

  if conf.swap:
    node.mountSwap()

  if (conf.storenode != "") or (conf.store == true):
    node.mountStore()

    var storenode: string

    if conf.storenode != "":
      storenode = conf.storenode
    else:
      echo "Store enabled, but no store nodes configured. Choosing one at random from test fleet..."
      
      storenode = selectRandomNode()

      echo "Connecting to storenode: " & storenode
    
    node.wakuStore.setPeer(parsePeerInfo(storenode))

    proc storeHandler(response: HistoryResponse) {.gcsafe.} =
      for msg in response.messages:
        let
          pb = Chat2Message.init(msg.payload)
          chatLine = if pb.isOk: pb[].toString()
                     else: string.fromBytes(msg.payload)
        echo &"{chatLine}"
      info "Hit store handler"

    await node.query(HistoryQuery(topics: @[DefaultContentTopic]), storeHandler)

  if conf.filternode != "":
    node.mountFilter()

    node.wakuFilter.setPeer(parsePeerInfo(conf.filternode))

    proc filterHandler(msg: WakuMessage) {.gcsafe.} =
      let
        pb = Chat2Message.init(msg.payload)
        chatLine = if pb.isOk: pb[].toString()
                   else: string.fromBytes(msg.payload)
      echo &"{chatLine}"
      info "Hit filter handler"

    await node.subscribe(
      FilterRequest(contentFilters: @[ContentFilter(topics: @[DefaultContentTopic])], topic: DefaultTopic, subscribe: true),
      filterHandler
    )

  # Subscribe to a topic
  # TODO To get end to end sender would require more information in payload
  # We could possibly indicate the relayer point with connection somehow probably (?)
  proc handler(topic: Topic, data: seq[byte]) {.async, gcsafe.} =
    let decoded = WakuMessage.init(data)
    if decoded.isOk():
      let msg = decoded.get()
      when PayloadV1:
        # Use Waku v1 payload encoding/encryption
        let
          keyInfo = KeyInfo(kind: Symmetric, symKey: DefaultSymKey)
          decodedPayload = decodePayload(decoded.get(), keyInfo)

        if decodedPayload.isOK():
          let
            pb = Chat2Message.init(decodedPayload.get().payload)
            chatLine = if pb.isOk: pb[].toString()
                       else: string.fromBytes(decodedPayload.get().payload)
          echo &"{chatLine}"
          chat.prompt = false
          showChatPrompt(chat)
          info "Hit subscribe handler", topic, chatLine,
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
        echo &"{chatLine}"
        chat.prompt = false
        showChatPrompt(chat)
        info "Hit subscribe handler", topic, chatLine,
          contentTopic = msg.contentTopic
    else:
      trace "Invalid encoded WakuMessage", error = decoded.error

  let topic = cast[Topic](DefaultTopic)
  node.subscribe(topic, handler)

  await chat.readWriteLoop()

  runForever()
  #await allFuturesThrowing(libp2pFuts)

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
