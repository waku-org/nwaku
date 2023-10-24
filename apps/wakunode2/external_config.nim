import
  std/strutils,
  stew/results,
  chronos,
  regex,
  confutils,
  confutils/defs,
  confutils/std/net,
  confutils/toml/defs as confTomlDefs,
  confutils/toml/std/net as confTomlNet,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  nimcrypto/utils,
  secp256k1
import
  ../../waku/common/confutils/envvar/defs as confEnvvarDefs,
  ../../waku/common/confutils/envvar/std/net as confEnvvarNet,
  ../../waku/common/logging,
  ../../waku/waku_enr

export
  confTomlDefs,
  confTomlNet,
  confEnvvarDefs,
  confEnvvarNet

type ConfResult*[T] = Result[T, string]
type ProtectedTopic* = object
  topic*: string
  key*: secp256k1.SkPublicKey

type
  WakuNodeConf* = object
    configFile* {.
      desc: "Loads configuration from a TOML file (cmd-line parameters take precedence)"
      name: "config-file" }: Option[InputFile]

    ##  Application-level configuration
    protectedTopics* {.
      desc: "Topics and its public key to be used for message validation, topic:pubkey. Argument may be repeated."
      defaultValue: newSeq[ProtectedTopic](0)
      name: "protected-topic" .}: seq[ProtectedTopic]

    ## Log configuration
    logLevel* {.
      desc: "Sets the log level for process. Supported levels: TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL",
      defaultValue: logging.LogLevel.INFO,
      name: "log-level" .}: logging.LogLevel

    logFormat* {.
      desc: "Specifies what kind of logs should be written to stdout. Suported formats: TEXT, JSON",
      defaultValue: logging.LogFormat.TEXT,
      name: "log-format" .}: logging.LogFormat

    ## General node config
    clusterId* {.
      desc: "Cluster id that the node is running in. Node in a different cluster id is disconnected."
      defaultValue: 0
      name: "cluster-id" }: uint32

    agentString* {.
      defaultValue: "nwaku",
      desc: "Node agent string which is used as identifier in network"
      name: "agent-string" .}: string

    nodekey* {.
      desc: "P2P node private key as 64 char hex string.",
      name: "nodekey" }: Option[PrivateKey]

    listenAddress* {.
      defaultValue: defaultListenAddress()
      desc: "Listening address for LibP2P (and Discovery v5, if enabled) traffic."
      name: "listen-address"}: ValidIpAddress

    tcpPort* {.
      desc: "TCP listening port."
      defaultValue: 60000
      name: "tcp-port" }: Port

    portsShift* {.
      desc: "Add a shift to all port numbers."
      defaultValue: 0
      name: "ports-shift" }: uint16

    nat* {.
      desc: "Specify method to use for determining public address. " &
            "Must be one of: any, none, upnp, pmp, extip:<IP>."
      defaultValue: "any" }: string

    extMultiAddrs* {.
      desc: "External multiaddresses to advertise to the network. Argument may be repeated."
      name: "ext-multiaddr" }: seq[string]

    extMultiAddrsOnly* {.
      desc: "Only announce external multiaddresses",
      defaultValue: false,
      name: "ext-multiaddr-only" }: bool

    maxConnections* {.
      desc: "Maximum allowed number of libp2p connections."
      defaultValue: 50
      name: "max-connections" }: uint16

    maxRelayPeers* {.
      desc: "Maximum allowed number of relay peers."
      name: "max-relay-peers" }: Option[int]

    peerStoreCapacity* {.
      desc: "Maximum stored peers in the peerstore."
      name: "peer-store-capacity" }: Option[int]

    peerPersistence* {.
      desc: "Enable peer persistence.",
      defaultValue: false,
      name: "peer-persistence" }: bool

    ## DNS addrs config

    dnsAddrs* {.
      desc: "Enable resolution of `dnsaddr`, `dns4` or `dns6` multiaddrs"
      defaultValue: true
      name: "dns-addrs" }: bool

    dnsAddrsNameServers* {.
      desc: "DNS name server IPs to query for DNS multiaddrs resolution. Argument may be repeated."
      defaultValue: @[ValidIpAddress.init("1.1.1.1"), ValidIpAddress.init("1.0.0.1")]
      name: "dns-addrs-name-server" }: seq[ValidIpAddress]

    dns4DomainName* {.
      desc: "The domain name resolving to the node's public IPv4 address",
      defaultValue: ""
      name: "dns4-domain-name" }: string

    ## Relay config

    relay* {.
      desc: "Enable relay protocol: true|false",
      defaultValue: true
      name: "relay" }: bool

    relayPeerExchange* {.
      desc: "Enable gossipsub peer exchange in relay protocol: true|false",
      defaultValue: false
      name: "relay-peer-exchange" }: bool

    rlnRelay* {.
      desc: "Enable spam protection through rln-relay: true|false",
      defaultValue: false
      name: "rln-relay" }: bool

    rlnRelayCredPath* {.
      desc: "The path for peristing rln-relay credential",
      defaultValue: ""
      name: "rln-relay-cred-path" }: string

    rlnRelayCredIndex* {.
      desc: "the index of the onchain commitment to use",
      name: "rln-relay-membership-index" }: Option[uint]

    rlnRelayDynamic* {.
      desc: "Enable  waku-rln-relay with on-chain dynamic group management: true|false",
      defaultValue: false
      name: "rln-relay-dynamic" }: bool

    rlnRelayIdKey* {.
      desc: "Rln relay identity secret key as a Hex string",
      defaultValue: ""
      name: "rln-relay-id-key" }: string

    rlnRelayIdCommitmentKey* {.
      desc: "Rln relay identity commitment key as a Hex string",
      defaultValue: ""
      name: "rln-relay-id-commitment-key" }: string

    rlnRelayEthClientAddress* {.
      desc: "WebSocket address of an Ethereum testnet client e.g., ws://localhost:8540/",
      defaultValue: "ws://localhost:8540/"
      name: "rln-relay-eth-client-address" }: string

    rlnRelayEthContractAddress* {.
      desc: "Address of membership contract on an Ethereum testnet",
      defaultValue: ""
      name: "rln-relay-eth-contract-address" }: string

    rlnRelayCredPassword* {.
      desc: "Password for encrypting RLN credentials",
      defaultValue: ""
      name: "rln-relay-cred-password" }: string

    rlnRelayTreePath* {.
      desc: "Path to the RLN merkle tree sled db (https://github.com/spacejam/sled)",
      defaultValue: ""
      name: "rln-relay-tree-path" }: string

    rlnRelayBandwidthThreshold* {.
      desc: "Message rate in bytes/sec after which verification of proofs should happen",
      defaultValue: 0 # to maintain backwards compatibility
      name: "rln-relay-bandwidth-threshold" }: int

    staticnodes* {.
      desc: "Peer multiaddr to directly connect with. Argument may be repeated."
      name: "staticnode" }: seq[string]

    keepAlive* {.
      desc: "Enable keep-alive for idle connections: true|false",
      defaultValue: false
      name: "keep-alive" }: bool

    topics* {.
      desc: "Default topic to subscribe to. Argument may be repeated. Deprecated! Please use pubsub-topic and/or content-topic instead."
      defaultValue: @["/waku/2/default-waku/proto"]
      name: "topic" .}: seq[string]

    pubsubTopics* {.
      desc: "Default pubsub topic to subscribe to. Argument may be repeated."
      name: "pubsub-topic" .}: seq[string]

    contentTopics* {.
      desc: "Default content topic to subscribe to. Argument may be repeated."
      name: "content-topic" .}: seq[string]

    ## Store and message store config

    store* {.
      desc: "Enable/disable waku store protocol",
      defaultValue: false,
      name: "store" }: bool

    storenode* {.
      desc: "Peer multiaddress to query for storage",
      defaultValue: "",
      name: "storenode" }: string

    storeMessageRetentionPolicy* {.
      desc: "Message store retention policy. Time retention policy: 'time:<seconds>'. Capacity retention policy: 'capacity:<count>'. Size retention policy: 'size:<xMB/xGB>'. Set to 'none' to disable.",
      defaultValue: "time:" & $2.days.seconds,
      name: "store-message-retention-policy" }: string

    storeMessageDbUrl* {.
      desc: "The database connection URL for peristent storage.",
      defaultValue: "sqlite://store.sqlite3",
      name: "store-message-db-url" }: string

    storeMessageDbVacuum* {.
      desc: "Enable database vacuuming at start. Only supported by SQLite database engine.",
      defaultValue: false,
      name: "store-message-db-vacuum" }: bool

    storeMessageDbMigration* {.
      desc: "Enable database migration at start.",
      defaultValue: true,
      name: "store-message-db-migration" }: bool

    ## Filter config

    filter* {.
      desc: "Enable filter protocol: true|false",
      defaultValue: false
      name: "filter" }: bool

    filternode* {.
      desc: "Peer multiaddr to request content filtering of messages.",
      defaultValue: ""
      name: "filternode" }: string

    filterTimeout* {.
      desc: "Timeout for filter node in seconds.",
      defaultValue: 14400 # 4 hours
      name: "filter-timeout" }: int64

    ## Lightpush config

    lightpush* {.
      desc: "Enable lightpush protocol: true|false",
      defaultValue: false
      name: "lightpush" }: bool

    lightpushnode* {.
      desc: "Peer multiaddr to request lightpush of published messages.",
      defaultValue: ""
      name: "lightpushnode" }: string

    ## JSON-RPC config

    rpc* {.
      desc: "Enable Waku JSON-RPC server: true|false",
      defaultValue: true
      name: "rpc" }: bool

    rpcAddress* {.
      desc: "Listening address of the JSON-RPC server.",
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "rpc-address" }: ValidIpAddress

    rpcPort* {.
      desc: "Listening port of the JSON-RPC server.",
      defaultValue: 8545
      name: "rpc-port" }: uint16

    rpcAdmin* {.
      desc: "Enable access to JSON-RPC Admin API: true|false",
      defaultValue: false
      name: "rpc-admin" }: bool

    rpcPrivate* {.
      desc: "Enable access to JSON-RPC Private API: true|false",
      defaultValue: false
      name: "rpc-private" }: bool

    ## REST HTTP config

    rest* {.
      desc: "Enable Waku REST HTTP server: true|false",
      defaultValue: false
      name: "rest" }: bool

    restAddress* {.
      desc: "Listening address of the REST HTTP server.",
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "rest-address" }: ValidIpAddress

    restPort* {.
      desc: "Listening port of the REST HTTP server.",
      defaultValue: 8645
      name: "rest-port" }: uint16

    restRelayCacheCapacity* {.
      desc: "Capacity of the Relay REST API message cache.",
      defaultValue: 30
      name: "rest-relay-cache-capacity" }: uint32

    restAdmin* {.
      desc: "Enable access to REST HTTP Admin API: true|false",
      defaultValue: false
      name: "rest-admin" }: bool

    restPrivate* {.
      desc: "Enable access to REST HTTP Private API: true|false",
      defaultValue: false
      name: "rest-private" }: bool

    ## Metrics config

    metricsServer* {.
      desc: "Enable the metrics server: true|false"
      defaultValue: false
      name: "metrics-server" }: bool

    metricsServerAddress* {.
      desc: "Listening address of the metrics server."
      defaultValue: ValidIpAddress.init("127.0.0.1")
      name: "metrics-server-address" }: ValidIpAddress

    metricsServerPort* {.
      desc: "Listening HTTP port of the metrics server."
      defaultValue: 8008
      name: "metrics-server-port" }: uint16

    metricsLogging* {.
      desc: "Enable metrics logging: true|false"
      defaultValue: true
      name: "metrics-logging" }: bool

    ## DNS discovery config

    dnsDiscovery* {.
      desc: "Enable discovering nodes via DNS"
      defaultValue: false
      name: "dns-discovery" }: bool

    dnsDiscoveryUrl* {.
      desc: "URL for DNS node list in format 'enrtree://<key>@<fqdn>'",
      defaultValue: ""
      name: "dns-discovery-url" }: string

    dnsDiscoveryNameServers* {.
      desc: "DNS name server IPs to query. Argument may be repeated."
      defaultValue: @[ValidIpAddress.init("1.1.1.1"), ValidIpAddress.init("1.0.0.1")]
      name: "dns-discovery-name-server" }: seq[ValidIpAddress]

    ## Discovery v5 config

    discv5Discovery* {.
      desc: "Enable discovering nodes via Node Discovery v5"
      defaultValue: false
      name: "discv5-discovery" }: bool

    discv5UdpPort* {.
      desc: "Listening UDP port for Node Discovery v5."
      defaultValue: 9000
      name: "discv5-udp-port" }: Port

    discv5BootstrapNodes* {.
      desc: "Text-encoded ENR for bootstrap node. Used when connecting to the network. Argument may be repeated."
      name: "discv5-bootstrap-node" }: seq[string]

    discv5EnrAutoUpdate* {.
      desc: "Discovery can automatically update its ENR with the IP address " &
            "and UDP port as seen by other nodes it communicates with. " &
            "This option allows to enable/disable this functionality"
      defaultValue: false
      name: "discv5-enr-auto-update" .}: bool

    discv5TableIpLimit* {.
      hidden
      desc: "Maximum amount of nodes with the same IP in discv5 routing tables"
      defaultValue: 10
      name: "discv5-table-ip-limit" .}: uint

    discv5BucketIpLimit* {.
      hidden
      desc: "Maximum amount of nodes with the same IP in discv5 routing table buckets"
      defaultValue: 2
      name: "discv5-bucket-ip-limit" .}: uint

    discv5BitsPerHop* {.
      hidden
      desc: "Kademlia's b variable, increase for less hops per lookup"
      defaultValue: 1
      name: "discv5-bits-per-hop" .}: int

    ## waku peer exchange config
    peerExchange* {.
      desc: "Enable waku peer exchange protocol (responder side): true|false",
      defaultValue: false
      name: "peer-exchange" }: bool

    peerExchangeNode* {.
      desc: "Peer multiaddr to send peer exchange requests to. (enables peer exchange protocol requester side)",
      defaultValue: ""
      name: "peer-exchange-node" }: string

    ## websocket config
    websocketSupport* {.
      desc: "Enable websocket:  true|false",
      defaultValue: false
      name: "websocket-support"}: bool

    websocketPort* {.
      desc: "WebSocket listening port."
      defaultValue: 8000
      name: "websocket-port" }: Port

    websocketSecureSupport* {.
      desc: "Enable secure websocket:  true|false",
      defaultValue: false
      name: "websocket-secure-support"}: bool

    websocketSecureKeyPath* {.
      desc: "Secure websocket key path:   '/path/to/key.txt' ",
      defaultValue: ""
      name: "websocket-secure-key-path"}: string

    websocketSecureCertPath* {.
      desc: "Secure websocket Certificate path:   '/path/to/cert.txt' ",
      defaultValue: ""
      name: "websocket-secure-cert-path"}: string

## Parsing

# NOTE: Keys are different in nim-libp2p
proc parseCmdArg*(T: type crypto.PrivateKey, p: string): T =
  try:
    let key = SkPrivateKey.init(utils.fromHex(p)).tryGet()
    crypto.PrivateKey(scheme: Secp256k1, skkey: key)
  except CatchableError:
    raise newException(ValueError, "Invalid private key")

proc completeCmdArg*(T: type crypto.PrivateKey, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type ProtectedTopic, p: string): T =
  let elements = p.split(":")
  if elements.len != 2:
    raise newException(ValueError, "Invalid format for protected topic expected topic:publickey")

  let publicKey = secp256k1.SkPublicKey.fromHex(elements[1])
  if publicKey.isErr:
    raise newException(ValueError, "Invalid public key")

  return ProtectedTopic(topic: elements[0], key: publicKey.get())

proc completeCmdArg*(T: type ProtectedTopic, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type ValidIpAddress, p: string): T =
  try:
    ValidIpAddress.init(p)
  except CatchableError:
    raise newException(ValueError, "Invalid IP address")

proc completeCmdArg*(T: type ValidIpAddress, val: string): seq[string] =
  return @[]

proc defaultListenAddress*(): ValidIpAddress =
  # TODO: How should we select between IPv4 and IPv6
  # Maybe there should be a config option for this.
  (static ValidIpAddress.init("0.0.0.0"))

proc parseCmdArg*(T: type Port, p: string): T =
  try:
    Port(parseInt(p))
  except CatchableError:
    raise newException(ValueError, "Invalid Port number")

proc completeCmdArg*(T: type Port, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type Option[int], p: string): T =
  try:
    some(parseInt(p))
  except CatchableError:
    raise newException(ValueError, "Invalid number")

proc parseCmdArg*(T: type Option[uint], p: string): T =
  try:
    some(parseUint(p))
  except CatchableError:
    raise newException(ValueError, "Invalid unsigned integer")

## Load

proc readValue*(r: var TomlReader, value: var crypto.PrivateKey) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(crypto.PrivateKey, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(r: var EnvvarReader, value: var crypto.PrivateKey) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(crypto.PrivateKey, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(r: var TomlReader, value: var ProtectedTopic) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(ProtectedTopic, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

proc readValue*(r: var EnvvarReader, value: var ProtectedTopic) {.raises: [SerializationError].} =
  try:
    value = parseCmdArg(ProtectedTopic, r.readValue(string))
  except CatchableError:
    raise newException(SerializationError, getCurrentExceptionMsg())

{.push warning[ProveInit]: off.}

proc load*(T: type WakuNodeConf, version=""): ConfResult[T] =
  try:
    let conf = WakuNodeConf.load(
      version=version,
      secondarySources = proc (conf: WakuNodeConf, sources: auto)
                              {.gcsafe, raises: [ConfigurationError].} =
        sources.addConfigFile(Envvar, InputFile("wakunode2"))

        if conf.configFile.isSome():
          sources.addConfigFile(Toml, conf.configFile.get())
    )
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())

{.pop.}
