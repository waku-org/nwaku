{.push raises: [].}

import
  std/[tables, options],
  chronos,
  web3,
  stint,
  ../on_chain/group_manager as onchain,
  ../../rln,
  ../../conversion_utils

logScope:
  topics = "waku rln_relay onchain_sync_group_manager"

# using the when predicate does not work within the contract macro, hence need to dupe
contract(WakuRlnContract):
  # this serves as an entrypoint into the rln membership set
  proc register(idCommitment: UInt256, userMessageLimit: EthereumUInt32)
  # Initializes the implementation contract (only used in unit tests)
  proc initialize(maxMessageLimit: UInt256)
  # this event is raised when a new member is registered
  proc MemberRegistered(rateCommitment: UInt256, index: EthereumUInt32) {.event.}
  # this function denotes existence of a given user
  proc memberExists(idCommitment: Uint256): UInt256 {.view.}
  # this constant describes the next index of a new member
  proc commitmentIndex(): UInt256 {.view.}
  # this constant describes the block number this contract was deployed on
  proc deployedBlockNumber(): UInt256 {.view.}
  # this constant describes max message limit of rln contract
  proc MAX_MESSAGE_LIMIT(): UInt256 {.view.}
  # this function returns the merkleProof for a given index
  proc merkleProofElements(index: Uint256): seq[Uint256] {.view.}
  # this function returns the Merkle root
  proc root(): Uint256 {.view.}

type OnchainSyncGroupManager* = ref object of GroupManager
  ethClientUrl*: string
  ethContractAddress*: string
  ethRpc*: Option[Web3]
  wakuRlnContract*: Option[WakuRlnContractWithSender]
  chainId*: uint
  keystorePath*: Option[string]
  keystorePassword*: Option[string]
  registrationHandler*: Option[RegistrationHandler]
  validRootBuffer*: Deque[MerkleNode]

proc fetchMerkleProof*(g: OnchainSyncGroupManager) {.async.} =
  let index = stuint(g.membershipIndex.get(), 256)
  try:
    let merkleProofInvocation = g.wakuRlnContract.get().merkleProofElements(index)
    let merkleProof = await merkleProofInvocation.call()
      # Await the contract call and extract the result
    return merkleProof
  except CatchableError:
    error "Failed to fetch merkle proof: " & getCurrentExceptionMsg()

proc fetchMerkleRoot*(g: OnchainSyncGroupManager) {.async.} =
  let merkleRootInvocation = g.wakuRlnContract.get().root()
  let merkleRoot = await merkleRootInvocation.call()
  return merkleRoot

template initializedGuard(g: OnchainGroupManager): untyped =
  if not g.initialized:
    raise newException(CatchableError, "OnchainGroupManager is not initialized")

template retryWrapper(
    g: OnchainSyncGroupManager, res: auto, errStr: string, body: untyped
): auto =
  retryWrapper(res, RetryStrategy.new(), errStr, g.onFatalErrorAction):
    body

method validateRoot*(
    g: OnchainSyncGroupManager, root: MerkleNode
): bool {.base, gcsafe, raises: [].} =
  if g.validRootBuffer.find(root) >= 0:
    return true
  return false

proc slideRootQueue*(g: OnchainSyncGroupManager): untyped =
  let rootRes = g.fetchMerkleRoot()
  if rootRes.isErr():
    raise newException(ValueError, "failed to get merkle root")
  let rootAfterUpdate = rootRes.get()

  let overflowCount = g.validRootBuffer.len - AcceptableRootWindowSize + 1
  if overflowCount > 0:
    for i in 0 ..< overflowCount:
      g.validRootBuffer.popFirst()

  g.validRootBuffer.addLast(rootAfterUpdate)

method atomicBatch*(
    g: OnchainSyncGroupManager,
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

  g.slideRootQueue()

method register*(
    g: OnchainSyncGroupManager, rateCommitment: RateCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  try:
    let leaf = rateCommitment.toLeaf().get()
    await g.registerBatch(@[leaf])
  except CatchableError:
    raise newException(ValueError, getCurrentExceptionMsg())

method registerBatch*(
    g: OnchainSyncGroupManager, rateCommitments: seq[RawRateCommitment]
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  await g.atomicBatch(g.latestIndex, rateCommitments)
  g.latestIndex += MembershipIndex(rateCommitments.len)

method register*(
    g: OnchainSyncGroupManager,
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

  debug "registering the member",
    idCommitment = idCommitment, userMessageLimit = userMessageLimit
  var txHash: TxHash
  g.retryWrapper(txHash, "Failed to register the member"):
    await wakuRlnContract.register(idCommitment, userMessageLimit.stuint(32)).send(
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

  let firstTopic = tsReceipt.logs[0].topics[0]
  # the hash of the signature of MemberRegistered(uint256,uint32) event is equal to the following hex value
  if firstTopic !=
      cast[FixedBytes[32]](keccak.keccak256.digest("MemberRegistered(uint256,uint32)").data):
    raise newException(ValueError, "register: unexpected event signature")

  # the arguments of the raised event i.e., MemberRegistered are encoded inside the data field
  # data = rateCommitment encoded as 256 bits || index encoded as 32 bits
  let arguments = tsReceipt.logs[0].data
  debug "tx log data", arguments = arguments
  let
    # In TX log data, uints are encoded in big endian
    membershipIndex = UInt256.fromBytesBE(arguments[32 ..^ 1])

  debug "parsed membershipIndex", membershipIndex
  g.userMessageLimit = some(userMessageLimit)
  g.membershipIndex = some(membershipIndex.toMembershipIndex())

  return

method withdraw*(
    g: OnchainSyncGroupManager, idCommitment: IDCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g) # TODO: after slashing is enabled on the contract

method withdrawBatch*(
    g: OnchainSyncGroupManager, idCommitments: seq[IDCommitment]
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

method generateProof*(
    g: OnchainSyncGroupManager,
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

  # Prepare the witness
  let witness = Witness(
    identity_secret: g.idCredentials.get().idSecretHash,
    user_message_limit: g.userMessageLimit.get(),
    message_id: messageId,
    path_elements: g.fetchMerkleProof(),
    identity_path_index: g.membershipIndex.get(),
    x: data,
    external_nullifier: poseidon_hash([epoch, rln_identifier]),
  )

  let serializedWitness = serialize(witness)
  var inputBuffer = toBuffer(serializedWitness)

  # Generate the proof using the zerokit API
  var outputBuffer: Buffer
  let success = generate_proof_with_witness(
    g.fetchMerkleRoot(), addr inputBuffer, addr outputBuffer
  )
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
  return ok(output)

method verifyProof*(
    g: OnchainSyncGroupManager, input: openArray[byte], proof: RateLimitProof
): GroupManagerResult[bool] {.base, gcsafe, raises: [].} =
  ## verifies the proof, returns an error if the proof verification fails
  ## returns true if the proof is valid
  var normalizedProof = proof
  # when we do this, we ensure that we compute the proof for the derived value
  # of the externalNullifier. The proof verification will fail if a malicious peer
  # attaches invalid epoch+rlnidentifier pair
  normalizedProof.externalNullifier = poseidon_hash([epoch, rln_identifier]).valueOr:
    return err("could not construct the external nullifier")

  var
    proofBytes = serialize(normalizedProof, data)
    proofBuffer = proofBytes.toBuffer()
    validProof: bool
    rootsBytes = serialize(validRoots)
    rootsBuffer = rootsBytes.toBuffer()

  trace "serialized proof", proof = byteutils.toHex(proofBytes)

  let verifyIsSuccessful = verify_with_roots(
    g.fetchMerkleRoot(), addr proofBuffer, addr rootsBuffer, addr validProof
  )
  if not verifyIsSuccessful:
    # something went wrong in verification call
    warn "could not verify validity of the proof", proof = proof
    return err("could not verify the proof")

  if not validProof:
    return ok(false)
  else:
    return ok(true)

method init*(g: OnchainSyncGroupManager): Future[GroupManagerResult[void]] {.async.} =
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
      .memberExists(keystoreCred.identityCredential.idCommitment.toUInt256())
      .call()
      if membershipExists == 0:
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
    cast[uint64](await wakuRlnContract.MAX_MESSAGE_LIMIT().call())

  proc onDisconnect() {.async.} =
    error "Ethereum client disconnected"
    let fromBlock = max(g.latestProcessedBlock, g.rlnContractDeployedBlockNumber)
    info "reconnecting with the Ethereum client, and restarting group sync",
      fromBlock = fromBlock
    var newEthRpc: Web3
    g.retryWrapper(newEthRpc, "Failed to reconnect with the Ethereum client"):
      await newWeb3(g.ethClientUrl)
    newEthRpc.ondisconnect = ethRpc.ondisconnect
    g.ethRpc = some(newEthRpc)

    try:
      await g.startOnchainSync()
    except CatchableError, Exception:
      g.onFatalErrorAction(
        "failed to restart group sync" & ": " & getCurrentExceptionMsg()
      )

  ethRpc.ondisconnect = proc() =
    asyncSpawn onDisconnect()

  waku_rln_number_registered_memberships.set(int64(g.rlnInstance.leavesSet()))
  g.initialized = true

  return ok()
