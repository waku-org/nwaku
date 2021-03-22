import
  std/[options, json, sequtils],
  eth/keys,
  ../../../v1/node/rpc/hexstrings,
  ../../protocol/waku_store/waku_store_types,
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
             cursor: if pagingOptions.cursor.isSome: pagingOptions.cursor.get else: Index(),
             direction: if pagingOptions.forward: PagingDirection.FORWARD else: PagingDirection.BACKWARD)

proc toPagingOptions*(pagingInfo: PagingInfo): StorePagingOptions =
  StorePagingOptions(pageSize: pagingInfo.pageSize,
                     cursor: some(pagingInfo.cursor),
                     forward: if pagingInfo.direction == PagingDirection.FORWARD: true else: false)

proc toStoreResponse*(historyResponse: HistoryResponse): StoreResponse =
  StoreResponse(messages: historyResponse.messages,
                pagingOptions: if historyResponse.pagingInfo != PagingInfo(): some(historyResponse.pagingInfo.toPagingOptions()) else: none(StorePagingOptions))

proc toWakuMessage*(relayMessage: WakuRelayMessage, version: uint32): WakuMessage =
  # @TODO global definition for default content topic
  const defaultCT = 0
  WakuMessage(payload: relayMessage.payload,
              contentTopic: if relayMessage.contentTopic.isSome: relayMessage.contentTopic.get else: defaultCT,
              version: version)

proc toWakuMessage*(relayMessage: WakuRelayMessage, version: uint32, rng: ref BrHmacDrbgContext, symkey: Option[SymKey], pubKey: Option[keys.PublicKey]): WakuMessage =
  # @TODO global definition for default content topic
  const defaultCT = 0

  let payload = Payload(payload: relayMessage.payload,
                        dst: pubKey,
                        symkey: symkey)

  WakuMessage(payload: payload.encode(version, rng[]).get(),
              contentTopic: if relayMessage.contentTopic.isSome: relayMessage.contentTopic.get else: defaultCT,
              version: version)

proc toWakuRelayMessage*(message: WakuMessage, symkey: Option[SymKey], privateKey: Option[keys.PrivateKey]): WakuRelayMessage =
  # @TODO global definition for default content topic

  let
    keyInfo = if symkey.isSome(): KeyInfo(kind: Symmetric, symKey: symkey.get()) 
              elif privateKey.isSome(): KeyInfo(kind: Asymmetric, privKey: privateKey.get())
              else: KeyInfo(kind: None)
    decoded = decodePayload(message, keyInfo)

  WakuRelayMessage(payload: decoded.get().payload,
                   contentTopic: some(message.contentTopic))

