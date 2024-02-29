when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  ../../waku/common/logging,
  ../../waku/waku_node,
  ../../waku/waku_rln_relay,
  ./node_spec,
  ./wire_spec

export 
  wire_spec,
  logging

type StealthCommitmentProtocol* = object
  wakuApp: App
  contentTopic: string


proc SCPHandler*(msg: WakuMessage) =
  let decodedRes = WakuStealthCommitmentMsg.decode(msg.payload)
  if decodedRes.isErr():
    error "could not decode scp message"
  let decoded = decodedRes.get()
  ## do something with the decoded message
  info "received SCP message: ", decoded


proc new*(wakuApp: App, contentTopic = ContentTopic("/wakustealthcommitments/1/app/proto")): StealthCommitmentProtocol =
  let SCP = StealthCommitmentProtocol(wakuApp: wakuApp, contentTopic: contentTopic)

  proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    if msg.contentTopic == contentTopic:
      SCPHandler(msg)

  wakuApp.node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), some(handler))
  return SCP


proc sendThruWaku*(self: StealthCommitmentProtocol, msg: seq[byte]): Future[Result[void, string]] {.async.} =
  let time = getTime().toUnix()
  var message = WakuMessage(payload: msg,
                            contentTopic: self.contentTopic, 
                            version: 0, 
                            timestamp: getNanosecondTime(time))

  (self.wakuApp.node.wakuRlnRelay.appendRLNProof(message, float64(time))).isOkOr:
    return err("could not append rate limit proof to the message: " & $error)

  (await self.wakuApp.node.publish(some(DefaultPubsubTopic), message)).isOkOr:
    return err("failed to publish message: " & $error)

  debug "rate limit proof is appended to the message"
  
  return ok()

proc sendRequest*(self: StealthCommitmentProtocol, spendingPubKey: SerializedKey, viewingPubKey: SerializedKey): Future[Result[void, string]] {.async.} =
  let request = constructRequest(spendingPubKey, viewingPubKey).encode()
  try:
    (await self.sendThruWaku(request.buffer)).isOkOr:
      return err("Could not send stealth commitment payload thru waku: " & $error)
  except CatchableError:
    return err("Could not send stealth commitment payload thru waku: " & getCurrentExceptionMsg())
  return ok()
  

proc sendResponse*(self: StealthCommitmentProtocol, stealthCommitment: SerializedKey, viewTag: SerializedKey): Future[Result[void, string]] {.async.} =
  let response = constructResponse(stealthCommitment, viewTag).encode()
  try:
    (await self.sendThruWaku(response.buffer)).isOkOr:
      return err("Could not send stealth commitment payload thru waku: " & $error)
  except CatchableError:
    return err("Could not send stealth commitment payload thru waku: " & getCurrentExceptionMsg())
  return ok()