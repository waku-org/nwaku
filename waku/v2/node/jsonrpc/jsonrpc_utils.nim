when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, json],
  eth/keys,
  ../../protocol/waku_message,
  ../../protocol/waku_store,
  ../../protocol/waku_store/rpc,
  ../../utils/time,
  ../waku_payload,
  ./hexstrings,
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

proc toPagingInfo*(pagingOptions: StorePagingOptions): PagingInfoRPC =
  PagingInfoRPC(
    pageSize: some(pagingOptions.pageSize),
    cursor: pagingOptions.cursor,
    direction: if pagingOptions.forward: some(PagingDirectionRPC.FORWARD)
               else: some(PagingDirectionRPC.BACKWARD)
  )

proc toPagingOptions*(pagingInfo: PagingInfoRPC): StorePagingOptions =
  StorePagingOptions(
    pageSize: pagingInfo.pageSize.get(0'u64),
    cursor: pagingInfo.cursor,
    forward: if pagingInfo.direction.isNone(): true
             else: pagingInfo.direction.get() == PagingDirectionRPC.FORWARD
  )

proc toJsonRPCStoreResponse*(response: HistoryResponse): StoreResponse =
  StoreResponse(
    messages: response.messages,
    pagingOptions: if response.cursor.isNone(): none(StorePagingOptions)
                   else: some(StorePagingOptions(
                     pageSize: uint64(response.messages.len), # This field will be deprecated soon
                     forward: true,  # Hardcoded. This field will be deprecated soon
                     cursor: response.cursor.map(toRPC)
                   ))
  )

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

