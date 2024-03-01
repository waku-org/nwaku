when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results,
  ../../waku/common/logging,
  ../../waku/waku_node,
  ../../waku/waku_rln_relay,
  ./erc_5564_interface as StealthCommitmentFFI,
  ./node_spec,
  ./wire_spec

export 
  wire_spec,
  logging

type StealthCommitmentProtocol* = object
  wakuApp: App
  contentTopic: string
  spendingKeyPair: StealthCommitmentFFI.KeyPair
  viewingKeyPair: StealthCommitmentFFI.KeyPair

proc deserialize(T: type StealthCommitmentFFI.PublicKey, v: SerializedKey): Result[T, string] =
  # deserialize seq[byte] into array[32, uint8]
  if v.len != 32:
    return err("invalid key length")
  var buf: array[32, uint8]
  for i in 0..<v.len:
    buf[i] = v[i]
  return ok(buf)

proc serialize(v: StealthCommitmentFFI.PublicKey | StealthCommitmentFFI.PrivateKey): SerializedKey =
  # serialize array[32, uint8] into seq[byte]
  var buf = newSeq[byte](v.len)
  for i in 0..<v.len:
    buf[i] = v[i]
  return buf

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

proc sendRequest*(self: StealthCommitmentProtocol): Future[Result[void, string]] {.async.} =
  let request = constructRequest(serialize(self.spendingKeyPair.publicKey), serialize(self.viewingKeyPair.publicKey)).encode()
  try:
    (await self.sendThruWaku(request.buffer)).isOkOr:
      return err("Could not send stealth commitment payload thru waku: " & $error)
  except CatchableError:
    return err("Could not send stealth commitment payload thru waku: " & getCurrentExceptionMsg())
  return ok()
  

proc sendResponse*(self: StealthCommitmentProtocol, stealthCommitment: StealthCommitmentFFI.PublicKey, viewTag: uint64): Future[Result[void, string]] {.async.} =
  let response = constructResponse(serialize(stealthCommitment), viewTag).encode()
  try:
    (await self.sendThruWaku(response.buffer)).isOkOr:
      return err("Could not send stealth commitment payload thru waku: " & $error)
  except CatchableError:
    return err("Could not send stealth commitment payload thru waku: " & getCurrentExceptionMsg())
  return ok()

type SCPHandler* = proc (msg: WakuMessage): Future[void] {.async.}
proc getSCPHandler(self: StealthCommitmentProtocol): SCPHandler =
  
  let handler = proc(msg: WakuMessage): Future[void] {.async.} =
    let decodedRes = WakuStealthCommitmentMsg.decode(msg.payload)
    if decodedRes.isErr():
      error "could not decode scp message"
    let decoded = decodedRes.get()
    if decoded.request == false:
      # do nothing
      return
    # send response
    # deseralize the keys
    let spendingKeyRes = deserialize(StealthCommitmentFFI.PublicKey, decoded.spendingPubKey.get())
    if spendingKeyRes.isErr():
      error "could not deserialize spending key: ", err = spendingKeyRes.error()
    let spendingKey = spendingKeyRes.get()
    let viewingKeyRes = (deserialize(StealthCommitmentFFI.PublicKey, decoded.viewingPubKey.get()))
    if viewingKeyRes.isErr():
      error "could not deserialize viewing key: ", err = viewingKeyRes.error()
    let viewingKey = viewingKeyRes.get()

    info "received spending key", spendingKey 
    info "received viewing key", viewingKey 
    let ephemeralKeyPairRes = StealthCommitmentFFI.generateKeyPair()
    if ephemeralKeyPairRes.isErr():
      error "could not generate ephemeral key pair: ", err = ephemeralKeyPairRes.error()
    let ephemeralKeyPair = ephemeralKeyPairRes.get()
    
    let stealthCommitmentRes = StealthCommitmentFFI.generateStealthCommitment(spendingKey, viewingKey, ephemeralKeyPair.privateKey)
    if stealthCommitmentRes.isErr():
      error "could not generate stealth commitment: ", err = stealthCommitmentRes.error()
    let stealthCommitment = stealthCommitmentRes.get()
    
    (await self.sendResponse(stealthCommitment.stealthCommitment, stealthCommitment.viewTag)).isOkOr:
      error "could not send response: ", err = $error

  return handler

proc new*(wakuApp: App, contentTopic = ContentTopic("/wakustealthcommitments/1/app/proto")): Result[StealthCommitmentProtocol, string] =
  let spendingKeyPair = StealthCommitmentFFI.generateKeyPair().valueOr:
    return err("could not generate spending key pair: " & $error)
  let viewingKeyPair = StealthCommitmentFFI.generateKeyPair().valueOr:
    return err("could not generate viewing key pair: " & $error)

  info "spending public key", publicKey = spendingKeyPair.publicKey
  info "viewing public key", publicKey = viewingKeyPair.publicKey

  let SCP = StealthCommitmentProtocol(wakuApp: wakuApp, 
                                      contentTopic: contentTopic,
                                      spendingKeyPair: spendingKeyPair,
                                      viewingKeyPair: viewingKeyPair)
    

  proc handler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    let scpHandler = getSCPHandler(SCP)
    if msg.contentTopic == contentTopic:
      try:
        await scpHandler(msg)
      except CatchableError:
        error "could not handle SCP message: ", err = getCurrentExceptionMsg()

  wakuApp.node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), some(handler))
  return ok(SCP)
