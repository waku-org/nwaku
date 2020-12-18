import
  eth/keys,
  ../../waku_types,
  std/[options,tables]

type
  StoreResponse* = object
    messages*: seq[WakuMessage]
    pagingOptions*: Option[StorePagingOptions]

  StorePagingOptions* = object
    ## This type holds some options for pagination
    pageSize*: uint64
    cursor*: Option[Index]
    forward*: bool

  WakuRelayMessage* = object
    payload*: seq[byte]
    contentTopic*: Option[ContentTopic]

  WakuPeer* = object
    multiaddr*: string
    protocol*: string
    connected*: bool

  WakuKeyPair* = object
    seckey*: PrivateKey
    pubkey*: PublicKey

  TopicCache* = TableRef[string, seq[WakuMessage]]

  MessageCache* = TableRef[ContentTopic, seq[WakuMessage]]
