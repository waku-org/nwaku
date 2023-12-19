when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/strformat,
  stew/results,
  chronicles,
  uri,
  json_serialization,
  presto/route
import
  ../../../waku_core,
  ../../../waku_store/common,
  ../../../waku_node,
  ../../../node/peer_manager,
  ../../../common/paging,
  ../../handlers,
  ../responses,
  ../serdes,
  ./types

export types

logScope:
  topics = "waku node rest store_api"

const futTimeout* = 5.seconds # Max time to wait for futures

const NoPeerNoDiscError* = RestApiResponse.preconditionFailed(
            "No suitable service peer & no discovery method")

# Queries the store-node with the query parameters and
# returns a RestApiResponse that is sent back to the api client.
proc performHistoryQuery(selfNode: WakuNode,
                         histQuery: HistoryQuery,
                         storePeer: RemotePeerInfo):

                      Future[RestApiResponse] {.async.} =

  let queryFut = selfNode.query(histQuery, storePeer)
  if not await queryFut.withTimeout(futTimeout):
    const msg = "No history response received (timeout)"
    error msg
    return RestApiResponse.internalServerError(msg)

  let res = queryFut.read()
  if res.isErr():
    const msg = "Error occurred in queryFut.read()"
    error msg, error=res.error
    return RestApiResponse.internalServerError(
                                fmt("{msg} [{res.error}]"))

  let storeResp = res.value.toStoreResponseRest()
  let resp = RestApiResponse.jsonResponse(storeResp, status=Http200)
  if resp.isErr():
    const msg = "Error building the json respose"
    error msg, error=resp.error
    return RestApiResponse.internalServerError(
                                fmt("{msg} [{resp.error}]"))

  return resp.get()

# Converts a string time representation into an Option[Timestamp].
# Only positive time is considered a valid Timestamp in the request
proc parseTime(input: Option[string]):
          Result[Option[Timestamp], string] =
  if input.isSome() and input.get() != "":
    try:
      let time = parseInt(input.get())
      if time > 0:
        return ok(some(Timestamp(time)))
    except ValueError:
      return err("Problem parsing time [" &
                  getCurrentExceptionMsg() & "]")

  return ok(none(Timestamp))

# Generates a history query cursor as per the given params
proc parseCursor(parsedPubsubTopic: Option[string],
                 senderTime: Option[string],
                 storeTime: Option[string],
                 digest: Option[string]):
  Result[Option[HistoryCursor], string] =

  # Parse sender time
  let parsedSenderTime = parseTime(senderTime)
  if not parsedSenderTime.isOk():
    return err(parsedSenderTime.error)

  # Parse store time
  let parsedStoreTime = parseTime(storeTime)
  if not parsedStoreTime.isOk():
    return err(parsedStoreTime.error)

  # Parse message digest
  let parsedMsgDigest = parseMsgDigest(digest)
  if not parsedMsgDigest.isOk():
    return err(parsedMsgDigest.error)

  # Parse cursor information
  if parsedPubsubTopic.isSome() and
     parsedSenderTime.value.isSome() and
     parsedStoreTime.value.isSome() and
     parsedMsgDigest.value.isSome():

     return ok(some(
            HistoryCursor(
                pubsubTopic: parsedPubsubTopic.get(),
                senderTime: parsedSenderTime.value.get(),
                storeTime: parsedStoreTime.value.get(),
                digest: parsedMsgDigest.value.get())
                ))
  else:
    return ok(none(HistoryCursor))

# Creates a HistoryQuery from the given params
proc createHistoryQuery(pubsubTopic: Option[string],
                        contentTopics: Option[string],
                        senderTime: Option[string],
                        storeTime: Option[string],
                        digest: Option[string],
                        startTime: Option[string],
                        endTime: Option[string],
                        pageSize: Option[string],
                        direction: Option[string]):

                  Result[HistoryQuery, string] =

  # Parse pubsubTopic parameter
  var parsedPubsubTopic = none(string)
  if pubsubTopic.isSome():
    let decodedPubsubTopic = decodeUrl(pubsubTopic.get())
    if decodedPubsubTopic != "":
      parsedPubsubTopic = some(decodedPubsubTopic)

  # Parse the content topics
  var parsedContentTopics = newSeq[ContentTopic](0)
  if contentTopics.isSome():
    let ctList = decodeUrl(contentTopics.get())
    if ctList != "":
      for ct in ctList.split(','):
        parsedContentTopics.add(ct)

  # Parse cursor information
  let parsedCursor = ? parseCursor(parsedPubsubTopic,
                                   senderTime,
                                   storeTime,
                                   digest)

  # Parse page size field
  var parsedPagedSize = DefaultPageSize
  if pageSize.isSome() and pageSize.get() != "":
    try:
      parsedPagedSize = uint64(parseInt(pageSize.get()))
    except CatchableError:
      return err("Problem parsing page size [" &
                  getCurrentExceptionMsg() & "]")

  # Parse start time
  let parsedStartTime = ? parseTime(startTime)

  # Parse end time
  let parsedEndTime = ? parseTime(endTime)

  # Parse ascending field
  var parsedDirection = default()
  if direction.isSome() and direction.get() != "":
    parsedDirection = direction.get().into()

  return ok(
      HistoryQuery(pubsubTopic: parsedPubsubTopic,
                   contentTopics: parsedContentTopics,
                   startTime: parsedStartTime,
                   endTime: parsedEndTime,
                   direction: parsedDirection,
                   pageSize: parsedPagedSize,
                   cursor: parsedCursor
                   ))

# Simple type conversion. The "Option[Result[string, cstring]]"
# type is used by the nim-presto library.
proc toOpt(self: Option[Result[string, cstring]]): Option[string] =
  if not self.isSome() or self.get().value == "":
    return none(string)
  if self.isSome() and self.get().value != "":
    return some(self.get().value)

# Subscribes the rest handler to attend "/store/v1/messages" requests
proc installStoreApiHandlers*(
  router: var RestRouter,
  node: WakuNode,
  discHandler: Option[DiscoveryHandler] = none(DiscoveryHandler),
  ) =

  # Handles the store-query request according to the passed parameters
  router.api(MethodGet,
      "/store/v1/messages") do (
      peerAddr: Option[string],
      pubsubTopic: Option[string],
      contentTopics: Option[string],
      senderTime: Option[string],
      storeTime: Option[string],
      digest: Option[string],
      startTime: Option[string],
      endTime: Option[string],
      pageSize: Option[string],
      ascending: Option[string]
      ) -> RestApiResponse:

    debug "REST-GET /store/v1/messages ", peer_addr = $peerAddr

    # All the GET parameters are URL-encoded (https://en.wikipedia.org/wiki/URL_encoding)
    # Example:
    # /store/v1/messages?peerAddr=%2Fip4%2F127.0.0.1%2Ftcp%2F60001%2Fp2p%2F16Uiu2HAmVFXtAfSj4EiR7mL2KvL4EE2wztuQgUSBoj2Jx2KeXFLN\&pubsubTopic=my-waku-topic

    # Parse the peer address parameter
    let parsedPeerAddr = parseUrlPeerAddr(peerAddr.toOpt()).valueOr:
      return RestApiResponse.badRequest(error)

    let peerAddr = parsedPeerAddr.valueOr:
      node.peerManager.selectPeer(WakuStoreCodec).valueOr:
        let handler = discHandler.valueOr:
          return NoPeerNoDiscError

        let peerOp = (await handler()).valueOr:
          return RestApiResponse.internalServerError($error)

        peerOp.valueOr:
          return RestApiResponse.preconditionFailed(
            "No suitable service peer & none discovered")

    # Parse the rest of the parameters and create a HistoryQuery
    let histQuery = createHistoryQuery(
                        pubsubTopic.toOpt(),
                        contentTopics.toOpt(),
                        senderTime.toOpt(),
                        storeTime.toOpt(),
                        digest.toOpt(),
                        startTime.toOpt(),
                        endTime.toOpt(),
                        pageSize.toOpt(),
                        ascending.toOpt()
                      )

    if not histQuery.isOk():
      return RestApiResponse.badRequest(histQuery.error)

    return await node.performHistoryQuery(histQuery.value, peerAddr)