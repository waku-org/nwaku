when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[algorithm, sequtils, strutils, tables, times, os, deques],
  chronicles, options, chronos, chronos/ratelimit, stint,
  confutils,
  web3, json,
  web3/ethtypes,
  eth/keys,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  stew/results,
  stew/[byteutils, arrayops]
import
  ./group_manager,
  ./rln,
  ./conversion_utils,
  ./constants,
  ./protocol_types,
  ./protocol_metrics
import
  ../waku_core,
  ../waku_keystore,
  ../utils/collector

logScope:
  topics = "waku rln_relay"

type WakuRlnConfig* = object
  rlnRelayDynamic*: bool
  rlnRelayCredIndex*: uint
  rlnRelayEthContractAddress*: string
  rlnRelayEthClientAddress*: string
  rlnRelayCredPath*: string
  rlnRelayCredPassword*: string
  rlnRelayTreePath*: string
  rlnRelayBandwidthThreshold*: int

proc createMembershipList*(rln: ptr RLN, n: int): RlnRelayResult[(
    seq[RawMembershipCredentials], string
  )] =
  ## createMembershipList produces a sequence of identity credentials in the form of (identity trapdoor, identity nullifier, identity secret hash, id commitment) in the hexadecimal format
  ## this proc also returns the root of a Merkle tree constructed out of the identity commitment keys of the generated list
  ## the output of this proc is used to initialize a static group keys (to test waku-rln-relay in the off-chain mode)
  ## Returns an error if it cannot create the membership list

  var output = newSeq[RawMembershipCredentials]()
  var idCommitments = newSeq[IDCommitment]()

  for i in 0..n-1:
    # generate an identity credential
    let idCredentialRes = rln.membershipKeyGen()
    if idCredentialRes.isErr():
      return err("could not generate an identity credential: " & idCredentialRes.error())
    let idCredential = idCredentialRes.get()
    let idTuple = (idCredential.idTrapdoor.inHex(), idCredential.idNullifier.inHex(), idCredential.idSecretHash.inHex(), idCredential.idCommitment.inHex())
    output.add(idTuple)
    idCommitments.add(idCredential.idCommitment)

  # Insert members into tree
  let membersAdded = rln.insertMembers(0, idCommitments)
  if not membersAdded:
    return err("could not insert members into the tree")

  let root = rln.getMerkleRoot().value().inHex()
  return ok((output, root))

proc calcEpoch*(t: float64): Epoch =
  ## gets time `t` as `flaot64` with subseconds resolution in the fractional part
  ## and returns its corresponding rln `Epoch` value
  let e = uint64(t/EpochUnitSeconds)
  return toEpoch(e)

type WakuRLNRelay* = ref object of RootObj
  # the log of nullifiers and Shamir shares of the past messages grouped per epoch
  nullifierLog*: Table[Epoch, seq[ProofMetadata]]
  lastEpoch*: Epoch # the epoch of the last published rln message
  groupManager*: GroupManager
  messageBucket*: Option[TokenBucket]

method stop*(rlnPeer: WakuRLNRelay) {.async.} =
  ## stops the rln-relay protocol
  ## Throws an error if it cannot stop the rln-relay protocol

  # stop the group sync, and flush data to tree db
  info "stopping rln-relay"
  await rlnPeer.groupManager.stop()

proc hasDuplicate*(rlnPeer: WakuRLNRelay,
                   proofMetadata: ProofMetadata): RlnRelayResult[bool] =
  ## returns true if there is another message in the  `nullifierLog` of the `rlnPeer` with the same
  ## epoch and nullifier as `proofMetadata`'s epoch and nullifier
  ## otherwise, returns false
  ## Returns an error if it cannot check for duplicates

  let externalNullifier = proofMetadata.externalNullifier
  # check if the epoch exists
  if not rlnPeer.nullifierLog.hasKey(externalNullifier):
    return ok(false)
  try:
    if rlnPeer.nullifierLog[externalNullifier].contains(proofMetadata):
      # there is an identical record, mark it as spam
      return ok(true)

    # check for a message with the same nullifier but different secret shares
    let matched = rlnPeer.nullifierLog[externalNullifier].filterIt((
        it.nullifier == proofMetadata.nullifier) and ((it.shareX != proofMetadata.shareX) or
        (it.shareY != proofMetadata.shareY)))

    if matched.len != 0:
      # there is a duplicate
      return ok(true)

    # there is no duplicate
    return ok(false)

  except KeyError as e:
    return err("the epoch was not found")

proc updateLog*(rlnPeer: WakuRLNRelay,
                proofMetadata: ProofMetadata): RlnRelayResult[void] =
  ## saves supplied proofMetadata `proofMetadata`
  ## in the `nullifierLog` of the `rlnPeer`
  ## Returns an error if it cannot update the log

  let externalNullifier = proofMetadata.externalNullifier
  # check if the externalNullifier exists
  if not rlnPeer.nullifierLog.hasKey(externalNullifier):
    rlnPeer.nullifierLog[externalNullifier] = @[proofMetadata]
    return ok()

  try:
    # check if an identical record exists
    if rlnPeer.nullifierLog[externalNullifier].contains(proofMetadata):
      # TODO: slashing logic
      return ok()
    # add proofMetadata to the log
    rlnPeer.nullifierLog[externalNullifier].add(proofMetadata)
    return ok()
  except KeyError as e:
    return err("the external nullifier was not found") # should never happen

proc getCurrentEpoch*(): Epoch =
  ## gets the current rln Epoch time
  return calcEpoch(epochTime())

proc absDiff*(e1, e2: Epoch): uint64 =
  ## returns the absolute difference between the two rln `Epoch`s `e1` and `e2`
  ## i.e., e1 - e2

  # convert epochs to their corresponding unsigned numerical values
  let
    epoch1 = fromEpoch(e1)
    epoch2 = fromEpoch(e2)

  # Manually perform an `abs` calculation
  if epoch1 > epoch2:
    return epoch1 - epoch2
  else:
    return epoch2 - epoch1

proc validateMessage*(rlnPeer: WakuRLNRelay,
                      msg: WakuMessage,
                      timeOption = none(float64)): MessageValidationResult =
  ## validate the supplied `msg` based on the waku-rln-relay routing protocol i.e.,
  ## the `msg`'s epoch is within MaxEpochGap of the current epoch
  ## the `msg` has valid rate limit proof
  ## the `msg` does not violate the rate limit
  ## `timeOption` indicates Unix epoch time (fractional part holds sub-seconds)
  ## if `timeOption` is supplied, then the current epoch is calculated based on that

  let decodeRes = RateLimitProof.init(msg.proof)
  if decodeRes.isErr():
    return MessageValidationResult.Invalid

  let proof = decodeRes.get()

  # track message count for metrics
  waku_rln_messages_total.inc()

  # checks if the `msg`'s epoch is far from the current epoch
  # it corresponds to the validation of rln external nullifier
  var epoch: Epoch
  if timeOption.isSome():
    epoch = calcEpoch(timeOption.get())
  else:
    # get current rln epoch
    epoch = getCurrentEpoch()

  let
    msgEpoch = proof.epoch
    # calculate the gaps
    gap = absDiff(epoch, msgEpoch)

  debug "epoch info", currentEpoch = fromEpoch(epoch), msgEpoch = fromEpoch(msgEpoch)

  # validate the epoch
  if gap > MaxEpochGap:
    # message's epoch is too old or too ahead
    # accept messages whose epoch is within +-MaxEpochGap from the current epoch
    warn "invalid message: epoch gap exceeds a threshold", gap = gap,
        payloadLen = msg.payload.len, msgEpoch = fromEpoch(proof.epoch)
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_epoch"])
    return MessageValidationResult.Invalid

  let rootValidationRes = rlnPeer.groupManager.validateRoot(proof.merkleRoot)
  if not rootValidationRes:
    debug "invalid message: provided root does not belong to acceptable window of roots", provided=proof.merkleRoot.inHex(), validRoots=rlnPeer.groupManager.validRoots.mapIt(it.inHex())
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_root"])
    return MessageValidationResult.Invalid

  # verify the proof
  let
    contentTopicBytes = msg.contentTopic.toBytes
    input = concat(msg.payload, contentTopicBytes)

  waku_rln_proof_verification_total.inc()
  waku_rln_proof_verification_duration_seconds.nanosecondTime:
    let proofVerificationRes = rlnPeer.groupManager.verifyProof(input, proof)

  if proofVerificationRes.isErr():
    waku_rln_errors_total.inc(labelValues=["proof_verification"])
    warn "invalid message: proof verification failed", payloadLen = msg.payload.len
    return MessageValidationResult.Invalid
  if not proofVerificationRes.value():
    # invalid proof
    debug "invalid message: invalid proof", payloadLen = msg.payload.len
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_proof"])
    return MessageValidationResult.Invalid

  # check if double messaging has happened
  let proofMetadataRes = proof.extractMetadata()
  if proofMetadataRes.isErr():
    waku_rln_errors_total.inc(labelValues=["proof_metadata_extraction"])
    return MessageValidationResult.Invalid
  let hasDup = rlnPeer.hasDuplicate(proofMetadataRes.get())
  if hasDup.isErr():
    waku_rln_errors_total.inc(labelValues=["duplicate_check"])
  elif hasDup.value == true:
    debug "invalid message: message is spam", payloadLen = msg.payload.len
    waku_rln_spam_messages_total.inc()
    return MessageValidationResult.Spam

  debug "message is valid", payloadLen = msg.payload.len
  let rootIndex = rlnPeer.groupManager.indexOfRoot(proof.merkleRoot)
  waku_rln_valid_messages_total.observe(rootIndex.toFloat())
  return MessageValidationResult.Valid

proc validateMessageAndUpdateLog*(
  rlnPeer: WakuRLNRelay,
  msg: WakuMessage,
  timeOption = none(float64)): MessageValidationResult =
  ## validates the message and updates the log to prevent double messaging
  ## in future messages

  let result = rlnPeer.validateMessage(msg, timeOption)

  let decodeRes = RateLimitProof.init(msg.proof)
  if decodeRes.isErr():
    return MessageValidationResult.Invalid

  let msgProof = decodeRes.get()
  let proofMetadataRes = msgProof.extractMetadata()

  if proofMetadataRes.isErr():
    return MessageValidationResult.Invalid

  # insert the message to the log (never errors)
  discard rlnPeer.updateLog(proofMetadataRes.get())

  return result

proc toRLNSignal*(wakumessage: WakuMessage): seq[byte] =
  ## it is a utility proc that prepares the `data` parameter of the proof generation procedure i.e., `proofGen`  that resides in the current module
  ## it extracts the `contentTopic` and the `payload` of the supplied `wakumessage` and serializes them into a byte sequence
  let
    contentTopicBytes = wakumessage.contentTopic.toBytes()
    output = concat(wakumessage.payload, contentTopicBytes)
  return output

proc appendRLNProof*(rlnPeer: WakuRLNRelay,
                     msg: var WakuMessage,
                     senderEpochTime: float64): bool =
  ## returns true if it can create and append a `RateLimitProof` to the supplied `msg`
  ## returns false otherwise
  ## `senderEpochTime` indicates the number of seconds passed since Unix epoch. The fractional part holds sub-seconds.
  ## The `epoch` field of `RateLimitProof` is derived from the provided `senderEpochTime` (using `calcEpoch()`)

  let input = msg.toRLNSignal()
  let epoch = calcEpoch(senderEpochTime)

  let proofGenRes = rlnPeer.groupManager.generateProof(input, epoch)

  if proofGenRes.isErr():
    return false

  msg.proof = proofGenRes.get().encode().buffer
  return true

proc generateRlnValidator*(wakuRlnRelay: WakuRLNRelay,
                           spamHandler: Option[SpamHandler] = none(SpamHandler)): pubsub.ValidatorHandler =
  ## this procedure is a thin wrapper for the pubsub addValidator method
  ## it sets a validator for waku messages, acting in the registered pubsub topic
  ## the message validation logic is according to https://rfc.vac.dev/spec/17/
  proc validator(topic: string, message: messages.Message): Future[pubsub.ValidationResult] {.async.} =
    trace "rln-relay topic validator is called"

    ## Check if enough tokens can be consumed from the message bucket
    try:
      if wakuRlnRelay.messageBucket.isSome() and
         wakuRlnRelay.messageBucket.get().tryConsume(message.data.len):
        return pubsub.ValidationResult.Accept
      else:
        info "message bandwidth limit exceeded, running rate limit proof validation"
    except OverflowDefect: # not a problem
      debug "not enough bandwidth, running rate limit proof validation"

    let decodeRes = WakuMessage.decode(message.data)
    if decodeRes.isOk():
      let wakumessage = decodeRes.value
      let decodeRes = RateLimitProof.init(wakumessage.proof)

      if decodeRes.isErr():
        return pubsub.ValidationResult.Reject

      let msgProof = decodeRes.get()

      # validate the message and update log
      let validationRes = wakuRlnRelay.validateMessageAndUpdateLog(wakumessage)

      let
        proof = toHex(msgProof.proof)
        epoch = fromEpoch(msgProof.epoch)
        root = inHex(msgProof.merkleRoot)
        shareX = inHex(msgProof.shareX)
        shareY = inHex(msgProof.shareY)
        nullifier = inHex(msgProof.nullifier)
        payload = string.fromBytes(wakumessage.payload)
      case validationRes:
        of Valid:
          debug "message validity is verified, relaying:",  contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
          trace "message validity is verified, relaying:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
          return pubsub.ValidationResult.Accept
        of Invalid:
          debug "message validity could not be verified, discarding:", contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
          trace "message validity could not be verified, discarding:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
          return pubsub.ValidationResult.Reject
        of Spam:
          debug "A spam message is found! yay! discarding:", contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
          trace "A spam message is found! yay! discarding:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
          if spamHandler.isSome():
            let handler = spamHandler.get()
            handler(wakumessage)
          return pubsub.ValidationResult.Reject
  return validator

proc mount(conf: WakuRlnConfig,
           registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)
          ): Future[WakuRlnRelay] {.async.} =
  var
    groupManager: GroupManager
  # create an RLN instance
  let rlnInstanceRes = createRLNInstance(tree_path = conf.rlnRelayTreePath)
  if rlnInstanceRes.isErr():
    raise newException(CatchableError, "RLN instance creation failed")
  let rlnInstance = rlnInstanceRes.get()
  if not conf.rlnRelayDynamic:
    # static setup
    let parsedGroupKeysRes = StaticGroupKeys.toIdentityCredentials()
    if parsedGroupKeysRes.isErr():
      raise newException(ValueError, "Static group keys are not valid")
    groupManager = StaticGroupManager(groupSize: StaticGroupSize,
                                      groupKeys: parsedGroupKeysRes.get(),
                                      membershipIndex: some(conf.rlnRelayCredIndex),
                                      rlnInstance: rlnInstance)
    # we don't persist credentials in static mode since they exist in ./constants.nim
  else:
    # dynamic setup
    proc useValueOrNone(s: string): Option[string] =
      if s == "": none(string) else: some(s)
    let
      rlnRelayCredPath = useValueOrNone(conf.rlnRelayCredPath)
      rlnRelayCredPassword = useValueOrNone(conf.rlnRelayCredPassword)
    groupManager = OnchainGroupManager(ethClientUrl: conf.rlnRelayEthClientAddress,
                                       ethContractAddress: $conf.rlnRelayEthContractAddress,
                                       rlnInstance: rlnInstance,
                                       registrationHandler: registrationHandler,
                                       keystorePath: rlnRelayCredPath,
                                       keystorePassword: rlnRelayCredPassword,
                                       membershipIndex: some(conf.rlnRelayCredIndex))
  # Initialize the groupManager
  await groupManager.init()
  # Start the group sync
  await groupManager.startGroupSync()

  let messageBucket = if conf.rlnRelayBandwidthThreshold > 0:
                      some(TokenBucket.new(conf.rlnRelayBandwidthThreshold))
                      else: none(TokenBucket)

  return WakuRLNRelay(groupManager: groupManager,
                      messageBucket: messageBucket)


proc new*(T: type WakuRlnRelay,
          conf: WakuRlnConfig,
          registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)
          ): Future[RlnRelayResult[WakuRlnRelay]] {.async.} =
  ## Mounts the rln-relay protocol on the node.
  ## The rln-relay protocol can be mounted in two modes: on-chain and off-chain.
  ## Returns an error if the rln-relay protocol could not be mounted.
  debug "rln-relay input validation passed"
  try:
    let rlnRelay = await mount(conf, registrationHandler)
    return ok(rlnRelay)
  except CatchableError as e:
    return err(e.msg)

