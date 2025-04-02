{.push raises: [].}

import
  os,
  web3,
  web3/eth_api_types,
  web3/primitives,
  eth/keys as keys,
  chronicles,
  nimcrypto/keccak as keccak,
  stint,
  json,
  std/tables,
  stew/[byteutils, arrayops],
  sequtils,
  strutils
import
  ../../../waku_keystore,
  ../../rln,
  ../../rln/rln_interface,
  ../../conversion_utils,
  ../group_manager_base,
  ./retry_wrapper

from strutils import parseHexInt

export group_manager_base

logScope:
  topics = "waku rln_relay onchain_group_manager"

# using the when predicate does not work within the contract macro, hence need to dupe
contract(WakuRlnContract):
  # this serves as an entrypoint into the rln membership set
  proc register(idCommitment: UInt256, userMessageLimit: EthereumUInt32, idCommitmentsToErase: seq[UInt256])
  # Initializes the implementation contract (only used in unit tests)
  proc initialize(maxMessageLimit: UInt256)
  # this event is raised when a new member is registered
  proc MembershipRegistered(idCommitment: UInt256, membershipRateLimit: UInt256, index: EthereumUInt32) {.event.}
  # this function denotes existence of a given user
  proc isInMembershipSet(idCommitment: Uint256): bool {.view.}
  # this constant describes the next index of a new member
  proc nextFreeIndex(): UInt256 {.view.}
  # this constant describes the block number this contract was deployed on
  proc deployedBlockNumber(): UInt256 {.view.}
  # this constant describes max message limit of rln contract
  proc maxMembershipRateLimit(): UInt256 {.view.}
  # this function returns the merkleProof for a given index
  proc getMerkleProof(index: Uint256): seq[Uint256] {.view.}
  # this function returns the Merkle root
  proc root(): Uint256 {.view.}

type
  WakuRlnContractWithSender = Sender[WakuRlnContract]
  OnchainGroupManager* = ref object of GroupManager
    ethClientUrl*: string
    ethPrivateKey*: Option[string]
    ethContractAddress*: string
    ethRpc*: Option[Web3]
    wakuRlnContract*: Option[WakuRlnContractWithSender]
    registrationTxHash*: Option[TxHash]
    chainId*: uint
    keystorePath*: Option[string]
    keystorePassword*: Option[string]
    registrationHandler*: Option[RegistrationHandler]
    latestProcessedBlock*: BlockNumber
    merkleProofCache*: seq[Uint256]

proc setMetadata*(
    g: OnchainGroupManager, lastProcessedBlock = none(BlockNumber)
): GroupManagerResult[void] =
  let normalizedBlock =
    if lastProcessedBlock.isSome():
      lastProcessedBlock.get()
    else:
      g.latestProcessedBlock
  try:
    let metadataSetRes = g.rlnInstance.setMetadata(
      RlnMetadata(
        lastProcessedBlock: normalizedBlock.uint64,
        chainId: g.chainId,
        contractAddress: g.ethContractAddress,
        validRoots: g.validRoots.toSeq(),
      )
    )
    if metadataSetRes.isErr():
      return err("failed to persist rln metadata: " & metadataSetRes.error)
  except CatchableError:
    return err("failed to persist rln metadata: " & getCurrentExceptionMsg())
  return ok()

proc fetchMerkleProofElements*(
    g: OnchainGroupManager
): Future[Result[seq[Uint256], string]] {.async.} =
  let index = stuint(g.membershipIndex.get(), 256)
  try:
    let merkleProofInvocation = g.wakuRlnContract.get().getMerkleProof(index)
    let merkleProof = await merkleProofInvocation.call()
    return ok(merkleProof)
  except CatchableError as e:
    error "Failed to fetch merkle proof", errMsg = e.msg

proc fetchMerkleRoot*(
    g: OnchainGroupManager
): Future[Result[Uint256, string]] {.async.} =
  try:
    let merkleRootInvocation = g.wakuRlnContract.get().root()
    let merkleRoot = await merkleRootInvocation.call()
    return ok(merkleRoot)
  except CatchableError as e:
    error "Failed to fetch Merkle root", errMsg = e.msg

template initializedGuard(g: OnchainGroupManager): untyped =
  if not g.initialized:
    raise newException(CatchableError, "OnchainGroupManager is not initialized")

template retryWrapper(
    g: OnchainGroupManager, res: auto, errStr: string, body: untyped
): auto =
  retryWrapper(res, RetryStrategy.new(), errStr, g.onFatalErrorAction):
    body

method validateRoot*(g: OnchainGroupManager, root: MerkleNode): bool =
  if g.validRoots.find(root) >= 0:
    return true
  return false

# Add this utility function to the file
proc toMerkleNode*(uint256Value: UInt256): MerkleNode =
  ## Converts a UInt256 value to a MerkleNode (array[32, byte])
  var merkleNode: MerkleNode
  let byteArray = uint256Value.toBytesBE()

  for i in 0 ..< min(byteArray.len, merkleNode.len):
    merkleNode[i] = byteArray[i]

  return merkleNode

proc updateRoots*(g: OnchainGroupManager): Future[bool] {.async.} =
  let rootRes = await g.fetchMerkleRoot()
  if rootRes.isErr():
    return false

  let merkleRoot = toMerkleNode(rootRes.get())
  if g.validRoots.len > 0 and g.validRoots[g.validRoots.len - 1] != merkleRoot:
    let overflowCount = g.validRoots.len - AcceptableRootWindowSize + 1
    if overflowCount > 0:
      for i in 0 ..< overflowCount:
        discard g.validRoots.popFirst()

    g.validRoots.addLast(merkleRoot)
    debug "~~~~~~~~~~~~~ Detected new Merkle root ~~~~~~~~~~~~~~~~",
      root = merkleRoot.toHex, totalRoots = g.validRoots.len
    return true
  else:
    debug "~~~~~~~~~~~~~ No new Merkle root ~~~~~~~~~~~~~~~~",
      root = merkleRoot.toHex, totalRoots = g.validRoots.len

  return false

# proc trackRootChanges*(g: OnchainGroupManager): Future[void] {.async.} =
#   ## Continuously track changes to the Merkle root
#   initializedGuard(g)
# 
#   let ethRpc = g.ethRpc.get()
#   let wakuRlnContract = g.wakuRlnContract.get()
# 
#   # Set up the polling interval - more frequent to catch roots
#   const rpcDelay = 5.seconds
# 
#   info "Starting to track Merkle root changes"
# 
#   while true:
#     debug "starting to update roots"
#     let rootUpdated = await g.updateRoots()
# 
#     if rootUpdated:
#       let proofResult = await g.fetchMerkleProofElements()
#       if proofResult.isErr():
#         error "Failed to fetch Merkle proof", error = proofResult.error
#       g.merkleProofCache = proofResult.get()
# 
#     debug "sleeping for 5 seconds"
#     await sleepAsync(rpcDelay)

method atomicBatch*(
    g: OnchainGroupManager,
    start: MembershipIndex,
    rateCommitments = newSeq[RawRateCommitment](),
    toRemoveIndices = newSeq[MembershipIndex](),
): Future[void] {.async: (raises: [Exception]), base.} =
  initializedGuard(g)

  if g.registerCb.isSome():
    var membersSeq = newSeq[Membership]()
    for i in 0 ..< rateCommitments.len:
      var index = start + MembershipIndex(i)
      debug "registering member to callback",
        rateCommitment = rateCommitments[i], index = index
      let member = Membership(rateCommitment: rateCommitments[i], index: index)
      membersSeq.add(member)
    await g.registerCb.get()(membersSeq)

  discard await g.updateRoots()

method register*(
    g: OnchainGroupManager, rateCommitment: RateCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  try:
    let leaf = rateCommitment.toLeaf().get()
    await g.atomicBatch(g.latestIndex, @[leaf])
    g.latestIndex += MembershipIndex(1)
  except CatchableError:
    raise newException(ValueError, getCurrentExceptionMsg())

method register*(
    g: OnchainGroupManager,
    identityCredential: IdentityCredential,
    userMessageLimit: UserMessageLimit,
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()
  let wakuRlnContract = g.wakuRlnContract.get()

  var gasPrice: int
  g.retryWrapper(gasPrice, "Failed to get gas price"):
    int(await ethRpc.provider.eth_gasPrice()) * 2
  let idCommitment = identityCredential.idCommitment.toUInt256()
  let idCommitmentsToErase: seq[UInt256] = @[]
  debug "registering the member",
    idCommitment = idCommitment, userMessageLimit = userMessageLimit, idCommitmentsToErase = idCommitmentsToErase
  var txHash: TxHash
  g.retryWrapper(txHash, "Failed to register the member"):
    await wakuRlnContract.register(idCommitment, userMessageLimit.stuint(32), idCommitmentsToErase).send(
      gasPrice = gasPrice
    )

  # wait for the transaction to be mined
  var tsReceipt: ReceiptObject
  g.retryWrapper(tsReceipt, "Failed to get the transaction receipt"):
    await ethRpc.getMinedTransactionReceipt(txHash)
  debug "registration transaction mined", txHash = txHash
  g.registrationTxHash = some(txHash)
  # the receipt topic holds the hash of signature of the raised events
  # TODO: make this robust. search within the event list for the event
  debug "ts receipt", receipt = tsReceipt[]

  if tsReceipt.status.isNone() or tsReceipt.status.get() != 1.Quantity:
    raise newException(ValueError, "register: transaction failed")

  let firstTopic = tsReceipt.logs[2].topics[0]
  # the hash of the signature of MembershipRegistered(uint256,uint256,uint32) event is equal to the following hex value
  if firstTopic !=
      cast[FixedBytes[32]](keccak.keccak256.digest("MembershipRegistered(uint256,uint256,uint32)").data):
    raise newException(ValueError, "register: unexpected event signature")

  # the arguments of the raised event i.e., MembershipRegistered are encoded inside the data field
  # data = rateCommitment encoded as 256 bits || index encoded as 32 bits
  let arguments = tsReceipt.logs[2].data
  debug "tx log data", arguments = arguments
  let
    # In TX log data, uints are encoded in big endian
    membershipIndex = UInt256.fromBytesBE(arguments[32 ..^ 1])

  debug "parsed membershipIndex", membershipIndex
  g.userMessageLimit = some(userMessageLimit)
  g.membershipIndex = some(membershipIndex.toMembershipIndex())

  return

method withdraw*(
    g: OnchainGroupManager, idCommitment: IDCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g) # TODO: after slashing is enabled on the contract

method withdrawBatch*(
    g: OnchainGroupManager, idCommitments: seq[IDCommitment]
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

proc toArray32*(s: seq[byte]): array[32, byte] =
  var output: array[32, byte]
  discard output.copyFrom(s)
  return output

proc toArray32Seq*(values: seq[UInt256]): seq[array[32, byte]] =
  ## Converts a sequence of UInt256 to a sequence of 32-byte arrays
  result = newSeqOfCap[array[32, byte]](values.len)
  for value in values:
    result.add(value.toBytesLE())

method generateProof*(
    g: OnchainGroupManager,
    data: seq[byte],
    epoch: Epoch,
    messageId: MessageId,
    rlnIdentifier = DefaultRlnIdentifier,
): Future[GroupManagerResult[RateLimitProof]] {.async.} =
  ## Generates an RLN proof using the cached Merkle proof and custom witness
  # Ensure identity credentials and membership index are set
  if g.idCredentials.isNone():
    return err("identity credentials are not set")
  if g.membershipIndex.isNone():
    return err("membership index is not set")
  if g.userMessageLimit.isNone():
    return err("user message limit is not set")

  let externalNullifierRes = poseidon(@[@(epoch), @(rlnIdentifier)])

  let witness = Witness(
    identity_secret: g.idCredentials.get().idSecretHash.toArray32(),
    user_message_limit: serialize(g.userMessageLimit.get()),
    message_id: serialize(messageId),
    path_elements: toArray32Seq(g.merkleProofCache),
    identity_path_index: @(toBytes(g.membershipIndex.get(), littleEndian)),
    x: toArray32(data),
    external_nullifier: externalNullifierRes.get(),
  )

  let serializedWitness = serialize(witness)
  var inputBuffer = toBuffer(serializedWitness)

  # Generate the proof using the zerokit API
  var outputBuffer: Buffer
  let success =
    generate_proof_with_witness(g.rlnInstance, addr inputBuffer, addr outputBuffer)
  if not success:
    return err("Failed to generate proof")

  # Parse the proof into a RateLimitProof object
  var proofValue = cast[ptr array[320, byte]](outputBuffer.`ptr`)
  let proofBytes: array[320, byte] = proofValue[]

  ## parse the proof as [ proof<128> | root<32> | external_nullifier<32> | share_x<32> | share_y<32> | nullifier<32> ]
  let
    proofOffset = 128
    rootOffset = proofOffset + 32
    externalNullifierOffset = rootOffset + 32
    shareXOffset = externalNullifierOffset + 32
    shareYOffset = shareXOffset + 32
    nullifierOffset = shareYOffset + 32

  var
    zkproof: ZKSNARK
    proofRoot, shareX, shareY: MerkleNode
    externalNullifier: ExternalNullifier
    nullifier: Nullifier

  discard zkproof.copyFrom(proofBytes[0 .. proofOffset - 1])
  discard proofRoot.copyFrom(proofBytes[proofOffset .. rootOffset - 1])
  discard
    externalNullifier.copyFrom(proofBytes[rootOffset .. externalNullifierOffset - 1])
  discard shareX.copyFrom(proofBytes[externalNullifierOffset .. shareXOffset - 1])
  discard shareY.copyFrom(proofBytes[shareXOffset .. shareYOffset - 1])
  discard nullifier.copyFrom(proofBytes[shareYOffset .. nullifierOffset - 1])

  # Create the RateLimitProof object
  let output = RateLimitProof(
    proof: zkproof,
    merkleRoot: proofRoot,
    externalNullifier: externalNullifier,
    epoch: epoch,
    rlnIdentifier: rlnIdentifier,
    shareX: shareX,
    shareY: shareY,
    nullifier: nullifier,
  )
  waku_rln_remaining_proofs_per_epoch.dec()
  waku_rln_total_generated_proofs.inc()
  return ok(output)

method verifyProof*(
    g: OnchainGroupManager, input: openArray[byte], proof: RateLimitProof
): GroupManagerResult[bool] {.gcsafe, raises: [].} =
  ## verifies the proof, returns an error if the proof verification fails
  ## returns true if the proof is valid
  var normalizedProof = proof
  # when we do this, we ensure that we compute the proof for the derived value
  # of the externalNullifier. The proof verification will fail if a malicious peer
  # attaches invalid epoch+rlnidentifier pair

  normalizedProof.externalNullifier = poseidon(
    @[@(proof.epoch), @(proof.rlnIdentifier)]
  ).valueOr:
    return err("could not construct the external nullifier")
  var
    proofBytes = serialize(normalizedProof, input)
    proofBuffer = proofBytes.toBuffer()
    validProof: bool
    rootsBytes = serialize(g.validRoots.items().toSeq())
    rootsBuffer = rootsBytes.toBuffer()

  trace "serialized proof", proof = byteutils.toHex(proofBytes)

  let verifyIsSuccessful = verify_with_roots(
    g.rlnInstance, addr proofBuffer, addr rootsBuffer, addr validProof
  )
  if not verifyIsSuccessful:
    # something went wrong in verification call
    warn "could not verify validity of the proof", proof = proof
    return err("could not verify the proof")

  if not validProof:
    return ok(false)
  else:
    return ok(true)

method onRegister*(g: OnchainGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  g.registerCb = some(cb)

method onWithdraw*(g: OnchainGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  g.withdrawCb = some(cb)

method init*(g: OnchainGroupManager): Future[GroupManagerResult[void]] {.async.} =
  # check if the Ethereum client is reachable
  var ethRpc: Web3
  g.retryWrapper(ethRpc, "Failed to connect to the Ethereum client"):
    await newWeb3(g.ethClientUrl)

  var fetchedChainId: uint
  g.retryWrapper(fetchedChainId, "Failed to get the chain id"):
    uint(await ethRpc.provider.eth_chainId())

  # Set the chain id
  if g.chainId == 0:
    warn "Chain ID not set in config, using RPC Provider's Chain ID",
      providerChainId = fetchedChainId

  if g.chainId != 0 and g.chainId != fetchedChainId:
    return err(
      "The RPC Provided a Chain ID which is different than the provided Chain ID: provided = " &
        $g.chainId & ", actual = " & $fetchedChainId
    )

  g.chainId = fetchedChainId

  if g.ethPrivateKey.isSome():
    let pk = g.ethPrivateKey.get()
    let parsedPk = keys.PrivateKey.fromHex(pk).valueOr:
      return err("failed to parse the private key" & ": " & $error)
    ethRpc.privateKey = Opt.some(parsedPk)
    ethRpc.defaultAccount =
      ethRpc.privateKey.get().toPublicKey().toCanonicalAddress().Address

  let contractAddress = web3.fromHex(web3.Address, g.ethContractAddress)
  let wakuRlnContract = ethRpc.contractSender(WakuRlnContract, contractAddress)

  g.ethRpc = some(ethRpc)
  g.wakuRlnContract = some(wakuRlnContract)

  if g.keystorePath.isSome() and g.keystorePassword.isSome():
    if not fileExists(g.keystorePath.get()):
      error "File provided as keystore path does not exist", path = g.keystorePath.get()
      return err("File provided as keystore path does not exist")

    var keystoreQuery = KeystoreMembership(
      membershipContract:
        MembershipContract(chainId: $g.chainId, address: g.ethContractAddress)
    )
    if g.membershipIndex.isSome():
      keystoreQuery.treeIndex = MembershipIndex(g.membershipIndex.get())
    waku_rln_membership_credentials_import_duration_seconds.nanosecondTime:
      let keystoreCred = getMembershipCredentials(
        path = g.keystorePath.get(),
        password = g.keystorePassword.get(),
        query = keystoreQuery,
        appInfo = RLNAppInfo,
      ).valueOr:
        return err("failed to get the keystore credentials: " & $error)

    g.membershipIndex = some(keystoreCred.treeIndex)
    g.userMessageLimit = some(keystoreCred.userMessageLimit)
    # now we check on the contract if the commitment actually has a membership
    try:
      let membershipExists = await wakuRlnContract
      .isInMembershipSet(keystoreCred.identityCredential.idCommitment.toUInt256())
      .call()
      if membershipExists == false:
        return err("the commitment does not have a membership")
    except CatchableError:
      return err("failed to check if the commitment has a membership")

    g.idCredentials = some(keystoreCred.identityCredential)

  let metadataGetOptRes = g.rlnInstance.getMetadata()
  if metadataGetOptRes.isErr():
    warn "could not initialize with persisted rln metadata"
  elif metadataGetOptRes.get().isSome():
    let metadata = metadataGetOptRes.get().get()
    if metadata.chainId != uint(g.chainId):
      return err("persisted data: chain id mismatch")
    if metadata.contractAddress != g.ethContractAddress.toLower():
      return err("persisted data: contract address mismatch")

  g.rlnRelayMaxMessageLimit =
    cast[uint64](await wakuRlnContract.maxMembershipRateLimit().call())

  asyncSpawn g.trackRootChanges()

  proc onDisconnect() {.async.} =
    error "Ethereum client disconnected"
    var newEthRpc: Web3
    g.retryWrapper(newEthRpc, "Failed to reconnect with the Ethereum client"):
      await newWeb3(g.ethClientUrl)
    newEthRpc.ondisconnect = ethRpc.ondisconnect
    g.ethRpc = some(newEthRpc)

  ethRpc.ondisconnect = proc() =
    asyncSpawn onDisconnect()

  waku_rln_number_registered_memberships.set(int64(g.rlnInstance.leavesSet()))
  g.initialized = true
  return ok()

method stop*(g: OnchainGroupManager): Future[void] {.async, gcsafe.} =
  if g.ethRpc.isSome():
    g.ethRpc.get().ondisconnect = nil
    await g.ethRpc.get().close()
  let flushed = g.rlnInstance.flush()
  if not flushed:
    error "failed to flush to the tree db"

  g.initialized = false
