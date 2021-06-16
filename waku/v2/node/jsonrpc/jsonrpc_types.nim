import
  std/[options,tables],
  eth/keys,
  ../../protocol/waku_message,
  ../../utils/pagination

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
    seckey*: keys.PrivateKey
    pubkey*: keys.PublicKey

  TopicCache* = TableRef[string, seq[WakuMessage]]

  MessageCache* = TableRef[ContentTopic, seq[WakuMessage]]
