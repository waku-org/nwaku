when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, json],
  eth/keys,
  ../../../v1/node/rpc/hexstrings,
  ../../protocol/waku_message,
  ../../protocol/waku_store,
  ../../utils/time,
  ../waku_payload,
  ./jsonrpc_types

export hexstrings

## Json marshalling

proc `%`*(value: WakuMessage): JsonNode =
  ## This ensures that seq[byte] fields are marshalled to hex-format JStrings
  ## (as defined in `hexstrings.nim`) rather than the default JArray[JInt]
  let jObj = newJObject()
  for k, v in value.fieldPairs:
    jObj[k] = %v
  return jObj

## Conversion tools
## Since the Waku v2 JSON-RPC API has its own defined types,
## we need to convert between these and the types for the Nim API

proc toPagingInfo*(pagingOptions: StorePagingOptions): PagingInfo =
  PagingInfo(pageSize: pagingOptions.pageSize,
             cursor: if pagingOptions.cursor.isSome: pagingOptions.cursor.get else: PagingIndex(),
             direction: if pagingOptions.forward: PagingDirection.FORWARD else: PagingDirection.BACKWARD)

proc toPagingOptions*(pagingInfo: PagingInfo): StorePagingOptions =
  StorePagingOptions(pageSize: pagingInfo.pageSize,
                     cursor: some(pagingInfo.cursor),
                     forward: if pagingInfo.direction == PagingDirection.FORWARD: true else: false)

proc toStoreResponse*(historyResponse: HistoryResponse): StoreResponse =
  StoreResponse(messages: historyResponse.messages,
                pagingOptions: if historyResponse.pagingInfo != PagingInfo(): some(historyResponse.pagingInfo.toPagingOptions()) else: none(StorePagingOptions))

proc toWakuMessage*(relayMessage: WakuRelayMessage, version: uint32): WakuMessage =
  var t: Timestamp
  if relayMessage.timestamp.isSome: 
    t = relayMessage.timestamp.get 
  else: 
    # incoming WakuRelayMessages with no timestamp will get 0 timestamp
    t = Timestamp(0)
  WakuMessage(payload: relayMessage.payload,
              contentTopic: relayMessage.contentTopic.get(DefaultContentTopic),
              version: version,
              timestamp: t) 

proc toWakuMessage*(relayMessage: WakuRelayMessage, version: uint32, rng: ref HmacDrbgContext, symkey: Option[SymKey], pubKey: Option[keys.PublicKey]): WakuMessage =
  let payload = Payload(payload: relayMessage.payload,
                        dst: pubKey,
                        symkey: symkey)

  var t: Timestamp
  if relayMessage.timestamp.isSome: 
    t = relayMessage.timestamp.get 
  else: 
    # incoming WakuRelayMessages with no timestamp will get 0 timestamp
    t = Timestamp(0)

  WakuMessage(payload: payload.encode(version, rng[]).get(),
              contentTopic: relayMessage.contentTopic.get(DefaultContentTopic),
              version: version,
              timestamp: t) 

proc toWakuRelayMessage*(message: WakuMessage, symkey: Option[SymKey], privateKey: Option[keys.PrivateKey]): WakuRelayMessage =
  let
    keyInfo = if symkey.isSome(): KeyInfo(kind: Symmetric, symKey: symkey.get()) 
              elif privateKey.isSome(): KeyInfo(kind: Asymmetric, privKey: privateKey.get())
              else: KeyInfo(kind: KeyKind.None)
    decoded = decodePayload(message, keyInfo)

  WakuRelayMessage(payload: decoded.get().payload,
                   contentTopic: some(message.contentTopic),
                   timestamp: some(message.timestamp))

