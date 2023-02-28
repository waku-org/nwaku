when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[algorithm, sequtils, strutils, tables, times, os, deques],
  chronicles, options, chronos, stint,
  confutils,
  strutils,
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
  ../../utils/time,
  ../waku_keystore

logScope:
  topics = "waku rln_relay"

type WakuRlnConfig* = object
  rlnRelayDynamic*: bool
  rlnRelayPubsubTopic*: PubsubTopic
  rlnRelayContentTopic*: ContentTopic
  rlnRelayMembershipIndex*: Option[uint]
  rlnRelayEthContractAddress*: string
  rlnRelayEthClientAddress*: string
  rlnRelayEthAccountPrivateKey*: string
  rlnRelayEthAccountAddress*: string
  rlnRelayCredPath*: string
  rlnRelayCredentialsPassword*: string

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
  pubsubTopic*: string # the pubsub topic for which rln relay is mounted
                       # contentTopic should be of type waku_message.ContentTopic, however, due to recursive module dependency, the underlying type of ContentTopic is used instead
                       # TODO a long-term solution is to place types with recursive dependency inside one file
  contentTopic*: string
  # the log of nullifiers and Shamir shares of the past messages grouped per epoch
  nullifierLog*: Table[Epoch, seq[ProofMetadata]]
  lastEpoch*: Epoch # the epoch of the last published rln message
  groupManager*: GroupManager

proc hasDuplicate*(rlnPeer: WakuRLNRelay, msg: WakuMessage): RlnRelayResult[bool] =
  ## returns true if there is another message in the  `nullifierLog` of the `rlnPeer` with the same
  ## epoch and nullifier as `msg`'s epoch and nullifier but different Shamir secret shares
  ## otherwise, returns false
  ## Returns an error if it cannot check for duplicates

  let decodeRes = RateLimitProof.init(msg.proof)
  if decodeRes.isErr():
    return err("failed to decode the RLN proof")

  let proof = decodeRes.get()

  # extract the proof metadata of the supplied `msg`
  let proofMD = ProofMetadata(
    nullifier: proof.nullifier,
    shareX: proof.shareX,
    shareY: proof.shareY
  )

  # check if the epoch exists
  if not rlnPeer.nullifierLog.hasKey(proof.epoch):
    return ok(false)
  try:
    if rlnPeer.nullifierLog[proof.epoch].contains(proofMD):
      # there is an identical record, ignore rhe mag
      return ok(false)

    # check for a message with the same nullifier but different secret shares
    let matched = rlnPeer.nullifierLog[proof.epoch].filterIt((
        it.nullifier == proofMD.nullifier) and ((it.shareX != proofMD.shareX) or
        (it.shareY != proofMD.shareY)))

    if matched.len != 0:
      # there is a duplicate
      return ok(true)

    # there is no duplicate
    return ok(false)

  except KeyError as e:
    return err("the epoch was not found")

proc updateLog*(rlnPeer: WakuRLNRelay, msg: WakuMessage): RlnRelayResult[bool] =
  ## extracts  the `ProofMetadata` of the supplied messages `msg` and
  ## saves it in the `nullifierLog` of the `rlnPeer`
  ## Returns an error if it cannot update the log

  let decodeRes = RateLimitProof.init(msg.proof)
  if decodeRes.isErr():
    return err("failed to decode the RLN proof")

  let proof = decodeRes.get()

  # extract the proof metadata of the supplied `msg`
  let proofMD = ProofMetadata(
    nullifier: proof.nullifier,
    shareX: proof.shareX,
    shareY: proof.shareY
  )
  debug "proof metadata", proofMD = proofMD

  # check if the epoch exists
  if not rlnPeer.nullifierLog.hasKey(proof.epoch):
    rlnPeer.nullifierLog[proof.epoch] = @[proofMD]
    return ok(true)

  try:
    # check if an identical record exists
    if rlnPeer.nullifierLog[proof.epoch].contains(proofMD):
      return ok(true)
    # add proofMD to the log
    rlnPeer.nullifierLog[proof.epoch].add(proofMD)
    return ok(true)
  except KeyError as e:
    return err("the epoch was not found")

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

proc validateMessage*(rlnPeer: WakuRLNRelay, msg: WakuMessage,
    timeOption: Option[float64] = none(float64)): MessageValidationResult =
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

  #  checks if the `msg`'s epoch is far from the current epoch
  # it corresponds to the validation of rln external nullifier
  var epoch: Epoch
  if timeOption.isSome():
    epoch = calcEpoch(timeOption.get())
  else:
    # get current rln epoch
    epoch = getCurrentEpoch()

  debug "current epoch", currentEpoch = fromEpoch(epoch)
  let
    msgEpoch = proof.epoch
    # calculate the gaps
    gap = absDiff(epoch, msgEpoch)

  debug "message epoch", msgEpoch = fromEpoch(msgEpoch)

  # validate the epoch
  if gap > MaxEpochGap:
    # message's epoch is too old or too ahead
    # accept messages whose epoch is within +-MaxEpochGap from the current epoch
    warn "invalid message: epoch gap exceeds a threshold", gap = gap,
        payload = string.fromBytes(msg.payload), msgEpoch = fromEpoch(proof.epoch)
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_epoch"])
    return MessageValidationResult.Invalid

  let rootValidationRes = rlnPeer.groupManager.validateRoot(proof.merkleRoot)
  if not rootValidationRes:
    debug "invalid message: provided root does not belong to acceptable window of roots", provided=proof.merkleRoot, validRoots=rlnPeer.groupManager.validRoots.mapIt(it.inHex())
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
    warn "invalid message: proof verification failed", payload = string.fromBytes(msg.payload)
    return MessageValidationResult.Invalid
  if not proofVerificationRes.value():
    # invalid proof
    debug "invalid message: invalid proof", payload = string.fromBytes(msg.payload)
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_proof"])
    return MessageValidationResult.Invalid

  # check if double messaging has happened
  let hasDup = rlnPeer.hasDuplicate(msg)
  if hasDup.isErr():
    waku_rln_errors_total.inc(labelValues=["duplicate_check"])
  elif hasDup.value == true:
    debug "invalid message: message is spam", payload = string.fromBytes(msg.payload)
    waku_rln_spam_messages_total.inc()
    return MessageValidationResult.Spam

  # insert the message to the log
  # the result of `updateLog` is discarded because message insertion is guaranteed by the implementation i.e.,
  # it will never error out
  discard rlnPeer.updateLog(msg)
  debug "message is valid", payload = string.fromBytes(msg.payload)
  let rootIndex = rlnPeer.groupManager.indexOfRoot(proof.merkleRoot)
  waku_rln_valid_messages_total.observe(rootIndex.toFloat())
  return MessageValidationResult.Valid

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
  ## it sets a validator for the waku messages published on the supplied pubsubTopic and contentTopic
  ## if contentTopic is empty, then validation takes place for All the messages published on the given pubsubTopic
  ## the message validation logic is according to https://rfc.vac.dev/spec/17/
  let contentTopic = wakuRlnRelay.contentTopic
  proc validator(topic: string, message: messages.Message): Future[pubsub.ValidationResult] {.async.} =
    trace "rln-relay topic validator is called"
    let decodeRes = WakuMessage.decode(message.data)
    if decodeRes.isOk():
      let
        wakumessage = decodeRes.value
        payload = string.fromBytes(wakumessage.payload)

      # check the contentTopic
      if (wakumessage.contentTopic != "") and (contentTopic != "") and (wakumessage.contentTopic != contentTopic):
        trace "content topic did not match:", contentTopic=wakumessage.contentTopic, payload=payload
        return pubsub.ValidationResult.Accept


      let decodeRes = RateLimitProof.init(wakumessage.proof)
      if decodeRes.isErr():
        return pubsub.ValidationResult.Reject

      let msgProof = decodeRes.get()

      # validate the message
      let
        validationRes = wakuRlnRelay.validateMessage(wakumessage)
        proof = toHex(msgProof.proof)
        epoch = fromEpoch(msgProof.epoch)
        root = inHex(msgProof.merkleRoot)
        shareX = inHex(msgProof.shareX)
        shareY = inHex(msgProof.shareY)
        nullifier = inHex(msgProof.nullifier)
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
    credentials: MembershipCredentials
    persistCredentials = false
  # create an RLN instance
  let rlnInstanceRes = createRLNInstance()
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
                                      membershipIndex: conf.rlnRelayMembershipIndex,
                                      rlnInstance: rlnInstance)
    # we don't persist credentials in static mode since they exist in ./constants.nim
  else:
    # dynamic setup
    proc useValueOrNone(s: string): Option[string] =
      if s == "": none(string) else: some(s)
    let
      ethPrivateKey = useValueOrNone(conf.rlnRelayEthAccountPrivateKey)
      rlnRelayCredPath = useValueOrNone(conf.rlnRelayCredPath)
      rlnRelayCredentialsPassword = useValueOrNone(conf.rlnRelayCredentialsPassword)
    groupManager = OnchainGroupManager(ethClientUrl: conf.rlnRelayEthClientAddress,
                                       ethContractAddress: $conf.rlnRelayEthContractAddress,
                                       ethPrivateKey: ethPrivateKey,
                                       rlnInstance: rlnInstance,
                                       registrationHandler: registrationHandler,
                                       keystorePath: rlnRelayCredPath,
                                       keystorePassword: rlnRelayCredentialsPassword,
                                       saveKeystore: true)

  # Initialize the groupManager
  await groupManager.init()
  # Start the group sync
  await groupManager.startGroupSync()

  return WakuRLNRelay(pubsubTopic: conf.rlnRelayPubsubTopic,
                      contentTopic: conf.rlnRelayContentTopic,
                      groupManager: groupManager)


proc new*(T: type WakuRlnRelay,
          conf: WakuRlnConfig,
          registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)
          ): Future[RlnRelayResult[WakuRlnRelay]] {.async.} =
  ## Mounts the rln-relay protocol on the node.
  ## The rln-relay protocol can be mounted in two modes: on-chain and off-chain.
  ## Returns an error if the rln-relay protocol could not be mounted.
  debug "rln-relay input validation passed"
  try:
    waku_rln_relay_mounting_duration_seconds.nanosecondTime:
      let rlnRelay = await mount(conf,
                                 registrationHandler)
    return ok(rlnRelay)
  except CatchableError as e:
    return err(e.msg)

