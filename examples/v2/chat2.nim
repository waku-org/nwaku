## chat2 is an example of usage of Waku v2. For suggested usage options, please
## see dingpu tutorial in docs folder.

when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

import std/[tables, strformat, strutils]
import confutils, chronicles, chronos, stew/shims/net as stewNet,
       eth/keys, bearssl, stew/[byteutils, endians2],
       nimcrypto/pbkdf2
import libp2p/[switch,                   # manage transports, a single entry point for dialing and listening
               crypto/crypto,            # cryptographic functions
               protocols/identify,       # identify the peer info of a peer
               stream/connection,        # create and close stream read / write connections
               transports/tcptransport,  # listen and dial to other peers using client-server protocol
               multiaddress,             # encode different addressing schemes. For example, /ip4/7.7.7.7/tcp/6543 means it is using IPv4 protocol and TCP
               peerinfo,                 # manage the information of a peer, such as peer ID and public / private key
               peerid,                   # Implement how peers interact
               protocols/protocol,       # define the protocol base type
               protocols/secure/secure,  # define the protocol of secure connection
               protocols/secure/secio,   # define the protocol of secure input / output, allows encrypted communication that uses public keys to validate signed messages instead of a certificate authority like in TLS
               muxers/muxer,             # define an interface for stream multiplexing, allowing peers to offer many protocols over a single connection
               muxers/mplex/mplex]       # define some contants and message types for stream multiplexing
import   ../../waku/v2/node/[config, wakunode2, waku_payload],
         ../../waku/v2/protocol/[waku_relay, waku_message],
         ../../waku/v2/protocol/waku_store/waku_store,
         ../../waku/v2/protocol/waku_filter/waku_filter,
         ../../waku/common/utils/nat

const Help = """
  Commands: /[?|help|connect|disconnect|exit]
  help: Prints this help
  connect: dials a remote peer
  disconnect: ends current session
  exit: closes the chat
"""

const
  PayloadV1* {.booldefine.} = false
  DefaultTopic = "/waku/2/default-waku/proto"

  Dingpu = "dingpu".toBytes
  DefaultContentTopic = ContentTopic(uint32.fromBytes(Dingpu))

# XXX Connected is a bit annoying, because incoming connections don't trigger state change
# Could poll connection pool or something here, I suppose
# TODO Ensure connected turns true on incoming connections, or get rid of it
type Chat = ref object
    node: WakuNode          # waku node for publishing, subscribing, etc
    transp: StreamTransport # transport streams between read & write file descriptor
    subscribed: bool        # indicates if a node is subscribed or not to a topic
    connected: bool         # if the node is connected to another peer
    started: bool           # if the node has started

type
  PrivateKey* = crypto.PrivateKey
  Topic* = wakunode2.Topic


# Similarly as Status public chats now.
proc generateSymKey(contentTopic: ContentTopic): SymKey =
  var ctx: HMAC[sha256]
  var symKey: SymKey
  if pbkdf2(ctx, contentTopic.toBytes(), "", 65356, symKey) != sizeof(SymKey):
    raise (ref Defect)(msg: "Should not occur as array is properly sized")

  symKey

let DefaultSymKey = generateSymKey(DefaultContentTopic)

proc initAddress(T: type MultiAddress, str: string): T =
  let address = MultiAddress.init(str).tryGet()
  if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
    result = address
  else:
    raise newException(ValueError,
                         "Invalid bootstrap node multi-address")

proc parsePeer(address: string): PeerInfo = 
  let multiAddr = MultiAddress.initAddress(address)
  let parts = address.split("/")
  result = PeerInfo.init(parts[^1], [multiAddr])

proc connectToNodes(c: Chat, nodes: seq[string]) {.async.} =
  echo "Connecting to nodes"
  await c.node.connectToNodes(nodes)
  c.connected = true

proc publish(c: Chat, line: string) =
  when PayloadV1:
    # Use Waku v1 payload encoding/encryption
    let
      payload = Payload(payload: line.toBytes(), symKey: some(DefaultSymKey))
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
    let message = WakuMessage(payload: line.toBytes(),
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

#    elif line.startsWith("/exit"):
#      if p.connected and p.conn.closed.not:
#        await p.conn.close()
#        p.connected = false
#
#      await p.switch.stop()
#      echo "quitting..."
#      quit(0)
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
    await node.mountRelay(conf.topics.split(" "), rlnRelayEnabled = conf.rlnrelay)
  else:
    await node.mountRelay(@[], rlnRelayEnabled = conf.rlnrelay)

  var chat = Chat(node: node, transp: transp, subscribed: true, connected: false, started: true)

  if conf.staticnodes.len > 0:
    await connectToNodes(chat, conf.staticnodes)

  let peerInfo = node.peerInfo
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  echo &"Listening on\n {listenStr}"

  if conf.swap:
    node.mountSwap()

  if conf.storenode != "":
    node.mountStore()

    node.wakuStore.setPeer(parsePeer(conf.storenode))

    proc storeHandler(response: HistoryResponse) {.gcsafe.} =
      for msg in response.messages:
        let payload = string.fromBytes(msg.payload)
        echo &"{payload}"
      info "Hit store handler"

    await node.query(HistoryQuery(topics: @[DefaultContentTopic]), storeHandler)

  if conf.filternode != "":
    node.mountFilter()

    node.wakuFilter.setPeer(parsePeer(conf.filternode))

    proc filterHandler(msg: WakuMessage) {.gcsafe.} =
      let payload = string.fromBytes(msg.payload)
      echo &"{payload}"
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
          let payload = string.fromBytes(decodedPayload.get().payload)
          echo &"{payload}"
          info "Hit subscribe handler", topic, payload,
            contentTopic = msg.contentTopic
        else:
          debug "Invalid encoded WakuMessage payload",
            error = decodedPayload.error
      else:
        # No payload encoding/encryption from Waku
        let payload = string.fromBytes(msg.payload)
        echo &"{payload}"
        info "Hit subscribe handler", topic, payload,
          contentTopic = msg.contentTopic
    else:
      trace "Invalid encoded WakuMessage", error = decoded.error

  let topic = cast[Topic](DefaultTopic)
  await node.subscribe(topic, handler)

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
