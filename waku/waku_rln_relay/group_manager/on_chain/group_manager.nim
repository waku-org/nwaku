when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  os,
  web3,
  web3/ethtypes,
  eth/keys as keys,
  chronicles,
  nimcrypto/keccak,
  stint,
  json,
  std/tables,
  stew/[byteutils, arrayops],
  sequtils,
  strutils
import
  ../../../waku_keystore,
  ../../rln,
  ../../conversion_utils,
  ../group_manager_base,
  ./retry_wrapper

from strutils import parseHexInt

export group_manager_base

logScope:
  topics = "waku rln_relay onchain_group_manager"

# using the when predicate does not work within the contract macro, hence need to dupe
when defined(rln_v2):
  contract(WakuRlnRegistry):
    # this describes the storage slot to use
    proc usingStorageIndex(): Uint16 {.pure.}
    # this map contains the address of a given storage slot
    proc storages(index: Uint16): Address {.pure.}
    # this serves as an entrypoint into the rln storage contract
    proc register(
      storageIndex: Uint16, idCommitment: Uint256, userMessageLimit: Uint256
    )

    # this creates a new storage on the rln registry
    proc newStorage(maxMessageLimit: Uint256)
    # Initializes the implementation contract (only used in unit tests)
    proc initialize()

  # membership contract interface
  contract(RlnStorage):
    # this event is raised when a new member is registered
    proc MemberRegistered(
      idCommitment: Uint256, userMessageLimit: Uint256, index: Uint256
    ) {.event.}

    # this constant contains the membership deposit of the contract
    proc MEMBERSHIP_DEPOSIT(): Uint256 {.pure.}
    # this map denotes existence of a given user
    proc memberExists(idCommitment: Uint256): Uint256 {.view.}
    # this constant describes the next index of a new member
    proc idCommitmentIndex(): Uint256 {.view.}
    # this constant describes the block number this contract was deployed on
    proc deployedBlockNumber(): Uint256 {.view.}
else:
  contract(WakuRlnRegistry):
    # this describes the storage slot to use
    proc usingStorageIndex(): Uint16 {.pure.}
    # this map contains the address of a given storage slot
    proc storages(index: Uint16): Address {.pure.}
    # this serves as an entrypoint into the rln storage contract
    proc register(storageIndex: Uint16, idCommitment: Uint256)
    # this creates a new storage on the rln registry
    proc newStorage()

  # membership contract interface
  contract(RlnStorage):
    # this event is raised when a new member is registered
    proc MemberRegistered(idCommitment: Uint256, index: Uint256) {.event.}
    # this constant contains the membership deposit of the contract
    proc MEMBERSHIP_DEPOSIT(): Uint256 {.pure.}
    # this map denotes existence of a given user
    proc memberExists(idCommitment: Uint256): Uint256 {.view.}
    # this constant describes the next index of a new member
    proc idCommitmentIndex(): Uint256 {.view.}
    # this constant describes the block number this contract was deployed on
    proc deployedBlockNumber(): Uint256 {.view.}

type
  RegistryContractWithSender = Sender[WakuRlnRegistry]
  RlnContractWithSender = Sender[RlnStorage]
  OnchainGroupManager* = ref object of GroupManager
    ethClientUrl*: string
    ethPrivateKey*: Option[string]
    ethContractAddress*: string
    ethRpc*: Option[Web3]
    rlnContract*: Option[RlnContractWithSender]
    rlnContractDeployedBlockNumber*: BlockNumber
    registryContract*: Option[RegistryContractWithSender]
    usingStorageIndex: Option[Uint16]
    membershipFee*: Option[Uint256]
    latestProcessedBlock*: BlockNumber
    registrationTxHash*: Option[TxHash]
    chainId*: Option[Quantity]
    keystorePath*: Option[string]
    keystorePassword*: Option[string]
    registrationHandler*: Option[RegistrationHandler]
    # this buffer exists to backfill appropriate roots for the merkle tree,
    # in event of a reorg. we store 5 in the buffer. Maybe need to revisit this,
    # because the average reorg depth is 1 to 2 blocks.
    validRootBuffer*: Deque[MerkleNode]
    # interval loop to shut down gracefully
    blockFetchingActive*: bool

const DefaultKeyStorePath* = "rlnKeystore.json"
const DefaultKeyStorePassword* = "password"

const DefaultBlockPollRate* = 6.seconds

template initializedGuard(g: OnchainGroupManager): untyped =
  if not g.initialized:
    raise newException(CatchableError, "OnchainGroupManager is not initialized")

proc resultifiedInitGuard(g: OnchainGroupManager): GroupManagerResult[void] =
  try:
    initializedGuard(g)
    return ok()
  except CatchableError:
    return err("OnchainGroupManager is not initialized")

template retryWrapper(
    g: OnchainGroupManager, res: auto, errStr: string, body: untyped
): auto =
  retryWrapper(res, RetryStrategy.new(), errStr, g.onFatalErrorAction):
    body

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
        lastProcessedBlock: normalizedBlock,
        chainId: uint64(g.chainId.get()),
        contractAddress: g.ethContractAddress,
        validRoots: g.validRoots.toSeq(),
      )
    )
    if metadataSetRes.isErr():
      return err("failed to persist rln metadata: " & metadataSetRes.error)
  except CatchableError:
    return err("failed to persist rln metadata: " & getCurrentExceptionMsg())
  return ok()

when defined(rln_v2):
  method atomicBatch*(
      g: OnchainGroupManager,
      start: MembershipIndex,
      rateCommitments = newSeq[RateCommitment](),
      toRemoveIndices = newSeq[MembershipIndex](),
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    # convert the rateCommitment struct to a leaf value
    let leaves = rateCommitments.toLeaves().valueOr:
      raise newException(
        ValueError, "failed to convert rateCommitments to leaves: " & $error
      )

    waku_rln_membership_insertion_duration_seconds.nanosecondTime:
      let operationSuccess =
        g.rlnInstance.atomicWrite(some(start), leaves, toRemoveIndices)
    if not operationSuccess:
      raise newException(CatchableError, "atomic batch operation failed")
    # TODO: when slashing is enabled, we need to track slashed members
    waku_rln_number_registered_memberships.set(int64(g.rlnInstance.leavesSet()))

    if g.registerCb.isSome():
      var membersSeq = newSeq[Membership]()
      for i in 0 ..< rateCommitments.len:
        var index = start + MembershipIndex(i)
        trace "registering member", rateCommitment = rateCommitments[i], index = index
        let member = Membership(rateCommitment: rateCommitments[i], index: index)
        membersSeq.add(member)
      await g.registerCb.get()(membersSeq)

    g.validRootBuffer = g.slideRootQueue()

else:
  method atomicBatch*(
      g: OnchainGroupManager,
      start: MembershipIndex,
      idCommitments = newSeq[IDCommitment](),
      toRemoveIndices = newSeq[MembershipIndex](),
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    waku_rln_membership_insertion_duration_seconds.nanosecondTime:
      let operationSuccess =
        g.rlnInstance.atomicWrite(some(start), idCommitments, toRemoveIndices)
    if not operationSuccess:
      raise newException(ValueError, "atomic batch operation failed")
    # TODO: when slashing is enabled, we need to track slashed members
    waku_rln_number_registered_memberships.set(int64(g.rlnInstance.leavesSet()))

    if g.registerCb.isSome():
      var membersSeq = newSeq[Membership]()
      for i in 0 ..< idCommitments.len:
        var index = start + MembershipIndex(i)
        trace "registering member", idCommitment = idCommitments[i], index = index
        let member = Membership(idCommitment: idCommitments[i], index: index)
        membersSeq.add(member)
      await g.registerCb.get()(membersSeq)

    g.validRootBuffer = g.slideRootQueue()

when defined(rln_v2):
  method register*(
      g: OnchainGroupManager, rateCommitment: RateCommitment
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    await g.registerBatch(@[rateCommitment])

else:
  method register*(
      g: OnchainGroupManager, idCommitment: IDCommitment
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    await g.registerBatch(@[idCommitment])

when defined(rln_v2):
  method registerBatch*(
      g: OnchainGroupManager, rateCommitments: seq[RateCommitment]
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    await g.atomicBatch(g.latestIndex, rateCommitments)
    g.latestIndex += MembershipIndex(rateCommitments.len)

else:
  method registerBatch*(
      g: OnchainGroupManager, idCommitments: seq[IDCommitment]
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    await g.atomicBatch(g.latestIndex, idCommitments)
    g.latestIndex += MembershipIndex(idCommitments.len)

when defined(rln_v2):
  method register*(
      g: OnchainGroupManager,
      identityCredential: IdentityCredential,
      userMessageLimit: UserMessageLimit,
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    let ethRpc = g.ethRpc.get()
    let registryContract = g.registryContract.get()
    let membershipFee = g.membershipFee.get()

    var gasPrice: int
    g.retryWrapper(gasPrice, "Failed to get gas price"):
      int(await ethRpc.provider.eth_gasPrice()) * 2
    let idCommitment = identityCredential.idCommitment.toUInt256()

    let storageIndex = g.usingStorageIndex.get()
    debug "registering the member",
      idCommitment = idCommitment,
      storageIndex = storageIndex,
      userMessageLimit = userMessageLimit
    var txHash: TxHash
    g.retryWrapper(txHash, "Failed to register the member"):
      await registryContract
      .register(storageIndex, idCommitment, u256(userMessageLimit))
      .send(gasPrice = gasPrice)

    # wait for the transaction to be mined
    var tsReceipt: ReceiptObject
    g.retryWrapper(tsReceipt, "Failed to get the transaction receipt"):
      await ethRpc.getMinedTransactionReceipt(txHash)
    debug "registration transaction mined", txHash = txHash
    g.registrationTxHash = some(txHash)
    # the receipt topic holds the hash of signature of the raised events
    # TODO: make this robust. search within the event list for the event
    let firstTopic = tsReceipt.logs[0].topics[0]
    # the hash of the signature of MemberRegistered(uint256,uint256,uint256) event is equal to the following hex value
    if firstTopic !=
        cast[FixedBytes[32]](keccak256.digest(
          "MemberRegistered(uint256,uint256,uint256)"
        ).data):
      raise newException(ValueError, "unexpected event signature")

    # the arguments of the raised event i.e., MemberRegistered are encoded inside the data field
    # data = pk encoded as 256 bits || index encoded as 256 bits || userMessageLimit encoded as 256 bits
    let arguments = tsReceipt.logs[0].data
    debug "tx log data", arguments = arguments
    let
      argumentsBytes = arguments
      # In TX log data, uints are encoded in big endian
      membershipIndex = UInt256.fromBytesBE(argumentsBytes[64 ..^ 1])

    g.userMessageLimit = some(userMessageLimit)
    g.membershipIndex = some(membershipIndex.toMembershipIndex())

    # don't handle member insertion into the tree here, it will be handled by the event listener
    return

else:
  method register*(
      g: OnchainGroupManager, credentials: IdentityCredential
  ): Future[void] {.async: (raises: [Exception]).} =
    initializedGuard(g)

    let ethRpc = g.ethRpc.get()
    let registryContract = g.registryContract.get()
    let membershipFee = g.membershipFee.get()

    var gasPrice: int
    g.retryWrapper(gasPrice, "Failed to get gas price"):
      int(await ethRpc.provider.eth_gasPrice()) * 2
    let idCommitment = credentials.idCommitment.toUInt256()

    let storageIndex = g.usingStorageIndex.get()
    debug "registering the member",
      idCommitment = idCommitment, storageIndex = storageIndex
    var txHash: TxHash
    g.retryWrapper(txHash, "Failed to register the member"):
      await registryContract.register(storageIndex, idCommitment).send(
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
    let firstTopic = tsReceipt.logs[0].topics[0]
    # the hash of the signature of MemberRegistered(uint256,uint256) event is equal to the following hex value
    if firstTopic !=
        cast[FixedBytes[32]](keccak256.digest("MemberRegistered(uint256,uint256)").data):
      raise newException(ValueError, "unexpected event signature")

    # the arguments of the raised event i.e., MemberRegistered are encoded inside the data field
    # data = pk encoded as 256 bits || index encoded as 256 bits
    let arguments = tsReceipt.logs[0].data
    debug "tx log data", arguments = arguments
    let
      argumentsBytes = arguments
      # In TX log data, uints are encoded in big endian
      eventIndex = UInt256.fromBytesBE(argumentsBytes[32 ..^ 1])

    g.membershipIndex = some(eventIndex.toMembershipIndex())

    # don't handle member insertion into the tree here, it will be handled by the event listener
    return

method withdraw*(
    g: OnchainGroupManager, idCommitment: IDCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g) # TODO: after slashing is enabled on the contract

method withdrawBatch*(
    g: OnchainGroupManager, idCommitments: seq[IDCommitment]
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

    # TODO: after slashing is enabled on the contract, use atomicBatch internally

proc parseEvent(
    event: type MemberRegistered, log: JsonNode
): GroupManagerResult[Membership] =
  ## parses the `data` parameter of the `MemberRegistered` event `log`
  ## returns an error if it cannot parse the `data` parameter
  var idComm: UInt256
  var index: UInt256
  when defined(rln_v2):
    var userMessageLimit: UInt256
  var data: string
  # Remove the 0x prefix
  try:
    data = strip0xPrefix(log["data"].getStr())
  except CatchableError:
    return err(
      "failed to parse the data field of the MemberRegistered event: " &
        getCurrentExceptionMsg()
    )
  var offset = 0
  try:
    # Parse the idComm
    offset += decode(data, offset, idComm)
    when defined(rln_v2):
      # Parse the userMessageLimit
      offset += decode(data, offset, userMessageLimit)
    # Parse the index
    offset += decode(data, offset, index)
    when defined(rln_v2):
      return ok(
        Membership(
          rateCommitment: RateCommitment(
            idCommitment: idComm.toIDCommitment(),
            userMessageLimit: userMessageLimit.toUserMessageLimit(),
          ),
          index: index.toMembershipIndex(),
        )
      )
    else:
      return ok(
        Membership(
          idCommitment: idComm.toIDCommitment(), index: index.toMembershipIndex()
        )
      )
  except CatchableError:
    return err("failed to parse the data field of the MemberRegistered event")

type BlockTable* = OrderedTable[BlockNumber, seq[(Membership, bool)]]

proc backfillRootQueue*(
    g: OnchainGroupManager, len: uint
): Future[void] {.async: (raises: [Exception]).} =
  if len > 0:
    # backfill the tree's acceptable roots
    for i in 0 .. len - 1:
      # remove the last root
      g.validRoots.popLast()
    for i in 0 .. len - 1:
      # add the backfilled root
      g.validRoots.addLast(g.validRootBuffer.popLast())

proc insert(
    blockTable: var BlockTable,
    blockNumber: BlockNumber,
    member: Membership,
    removed: bool,
) =
  let memberTuple = (member, removed)
  if blockTable.hasKeyOrPut(blockNumber, @[memberTuple]):
    try:
      blockTable[blockNumber].add(memberTuple)
    except KeyError: # qed
      error "could not insert member into block table",
        blockNumber = blockNumber, member = member

proc getRawEvents(
    g: OnchainGroupManager, fromBlock: BlockNumber, toBlock: BlockNumber
): Future[JsonNode] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()
  let rlnContract = g.rlnContract.get()

  var events: JsonNode
  g.retryWrapper(events, "Failed to get the events"):
    await rlnContract.getJsonLogs(
      MemberRegistered,
      fromBlock = some(fromBlock.blockId()),
      toBlock = some(toBlock.blockId()),
    )
  return events

proc getBlockTable(
    g: OnchainGroupManager, fromBlock: BlockNumber, toBlock: BlockNumber
): Future[BlockTable] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  var blockTable = default(BlockTable)

  let events = await g.getRawEvents(fromBlock, toBlock)

  if events.len == 0:
    trace "no events found"
    return blockTable

  for event in events:
    let blockNumber = parseHexInt(event["blockNumber"].getStr()).uint
    let removed = event["removed"].getBool()
    let parsedEventRes = parseEvent(MemberRegistered, event)
    if parsedEventRes.isErr():
      error "failed to parse the MemberRegistered event", error = parsedEventRes.error()
      raise newException(ValueError, "failed to parse the MemberRegistered event")
    let parsedEvent = parsedEventRes.get()
    blockTable.insert(blockNumber, parsedEvent, removed)

  return blockTable

proc handleEvents(
    g: OnchainGroupManager, blockTable: BlockTable
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  for blockNumber, members in blockTable.pairs():
    try:
      let startIndex = blockTable[blockNumber].filterIt(not it[1])[0][0].index
      let removalIndices = members.filterIt(it[1]).mapIt(it[0].index)
      when defined(rln_v2):
        let rateCommitments = members.mapIt(it[0].rateCommitment)
        await g.atomicBatch(
          start = startIndex,
          rateCommitments = rateCommitments,
          toRemoveIndices = removalIndices,
        )
        g.latestIndex = startIndex + MembershipIndex(rateCommitments.len)
        trace "new members added to the Merkle tree", commitments = rateCommitments
      else:
        let idCommitments = members.mapIt(it[0].idCommitment)
        await g.atomicBatch(
          start = startIndex,
          idCommitments = idCommitments,
          toRemoveIndices = removalIndices,
        )
        g.latestIndex = startIndex + MembershipIndex(idCommitments.len)
        trace "new members added to the Merkle tree", commitments = idCommitments
    except CatchableError:
      error "failed to insert members into the tree", error = getCurrentExceptionMsg()
      raise newException(ValueError, "failed to insert members into the tree")

  return

proc handleRemovedEvents(
    g: OnchainGroupManager, blockTable: BlockTable
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  # count number of blocks that have been removed
  var numRemovedBlocks: uint = 0
  for blockNumber, members in blockTable.pairs():
    if members.anyIt(it[1]):
      numRemovedBlocks += 1

  await g.backfillRootQueue(numRemovedBlocks)

proc getAndHandleEvents(
    g: OnchainGroupManager, fromBlock: BlockNumber, toBlock: BlockNumber
): Future[bool] {.async: (raises: [Exception]).} =
  initializedGuard(g)
  let blockTable = await g.getBlockTable(fromBlock, toBlock)
  try:
    await g.handleEvents(blockTable)
    await g.handleRemovedEvents(blockTable)
  except CatchableError:
    error "failed to handle events", error = getCurrentExceptionMsg()
    raise newException(ValueError, "failed to handle events")

  g.latestProcessedBlock = toBlock
  return true

proc runInInterval(g: OnchainGroupManager, cb: proc, interval: Duration) =
  g.blockFetchingActive = false

  proc runIntervalLoop() {.async, gcsafe.} =
    g.blockFetchingActive = true

    while g.blockFetchingActive:
      var retCb: bool
      g.retryWrapper(retCb, "Failed to run the interval block fetching loop"):
        await cb()
      await sleepAsync(interval)

  # using asyncSpawn is OK here since
  # we make use of the error handling provided by
  # OnFatalErrorHandler
  asyncSpawn runIntervalLoop()

proc getNewBlockCallback(g: OnchainGroupManager): proc =
  let ethRpc = g.ethRpc.get()
  proc wrappedCb(): Future[bool] {.async, gcsafe.} =
    var latestBlock: BlockNumber
    g.retryWrapper(latestBlock, "Failed to get the latest block number"):
      cast[BlockNumber](await ethRpc.provider.eth_blockNumber())

    if latestBlock <= g.latestProcessedBlock:
      return
    # get logs from the last block
    # inc by 1 to prevent double processing
    let fromBlock = g.latestProcessedBlock + 1
    var handleBlockRes: bool
    g.retryWrapper(handleBlockRes, "Failed to handle new block"):
      await g.getAndHandleEvents(fromBlock, latestBlock)

    # cannot use isOkOr here because results in a compile-time error that
    # shows the error is void for some reason
    let setMetadataRes = g.setMetadata()
    if setMetadataRes.isErr():
      error "failed to persist rln metadata", error = setMetadataRes.error

    return handleBlockRes

  return wrappedCb

proc startListeningToEvents(
    g: OnchainGroupManager
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()
  let newBlockCallback = g.getNewBlockCallback()
  g.runInInterval(newBlockCallback, DefaultBlockPollRate)

proc batchAwaitBlockHandlingFuture(
    g: OnchainGroupManager, futs: seq[Future[bool]]
): Future[void] {.async: (raises: [Exception]).} =
  for fut in futs:
    try:
      var handleBlockRes: bool
      g.retryWrapper(handleBlockRes, "Failed to handle block"):
        await fut
    except CatchableError:
      raise newException(
        CatchableError, "could not fetch events from block: " & getCurrentExceptionMsg()
      )

proc startOnchainSync(
    g: OnchainGroupManager
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()

  # static block chunk size
  let blockChunkSize = 2_000
  # delay between rpc calls to not overload the rate limit
  let rpcDelay = 200.milliseconds
  # max number of futures to run concurrently
  let maxFutures = 10

  var fromBlock =
    if g.latestProcessedBlock > g.rlnContractDeployedBlockNumber:
      info "syncing from last processed block", blockNumber = g.latestProcessedBlock
      g.latestProcessedBlock + 1
    else:
      info "syncing from rln contract deployed block",
        blockNumber = g.rlnContractDeployedBlockNumber
      g.rlnContractDeployedBlockNumber

  var futs = newSeq[Future[bool]]()
  var currentLatestBlock: BlockNumber
  g.retryWrapper(currentLatestBlock, "Failed to get the latest block number"):
    cast[BlockNumber](await ethRpc.provider.eth_blockNumber())

  try:
    # we always want to sync from last processed block => latest
    # chunk events
    while true:
      # if the fromBlock is less than 2k blocks behind the current block
      # then fetch the new toBlock
      if fromBlock >= currentLatestBlock:
        break

      if fromBlock + blockChunkSize.uint > currentLatestBlock.uint:
        g.retryWrapper(currentLatestBlock, "Failed to get the latest block number"):
          cast[BlockNumber](await ethRpc.provider.eth_blockNumber())

      let toBlock = min(fromBlock + BlockNumber(blockChunkSize), currentLatestBlock)
      debug "fetching events", fromBlock = fromBlock, toBlock = toBlock
      await sleepAsync(rpcDelay)
      futs.add(g.getAndHandleEvents(fromBlock, toBlock))
      if futs.len >= maxFutures or toBlock == currentLatestBlock:
        await g.batchAwaitBlockHandlingFuture(futs)
        g.setMetadata(lastProcessedBlock = some(toBlock)).isOkOr:
          error "failed to persist rln metadata", error = $error
        futs = newSeq[Future[bool]]()
      fromBlock = toBlock + 1
  except CatchableError:
    raise newException(
      CatchableError,
      "failed to get the history/reconcile missed blocks: " & getCurrentExceptionMsg(),
    )

  # listen to blockheaders and contract events
  try:
    await g.startListeningToEvents()
  except CatchableError:
    raise newException(
      ValueError, "failed to start listening to events: " & getCurrentExceptionMsg()
    )

method startGroupSync*(
    g: OnchainGroupManager
): Future[GroupManagerResult[void]] {.async.} =
  ?resultifiedInitGuard(g)
  # Get archive history
  try:
    await startOnchainSync(g)
    return ok()
  except CatchableError, Exception:
    return err("failed to start group sync: " & getCurrentExceptionMsg())

method onRegister*(g: OnchainGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  g.registerCb = some(cb)

method onWithdraw*(g: OnchainGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  g.withdrawCb = some(cb)

method init*(g: OnchainGroupManager): Future[GroupManagerResult[void]] {.async.} =
  # check if the Ethereum client is reachable
  var ethRpc: Web3
  g.retryWrapper(ethRpc, "Failed to connect to the Ethereum client"):
    await newWeb3(g.ethClientUrl)

  # Set the chain id
  var chainId: Quantity
  g.retryWrapper(chainId, "Failed to get the chain id"):
    await ethRpc.provider.eth_chainId()
  g.chainId = some(chainId)

  if g.ethPrivateKey.isSome():
    let pk = g.ethPrivateKey.get()
    let parsedPk = keys.PrivateKey.fromHex(pk).valueOr:
      return err("failed to parse the private key" & ": " & $error)
    ethRpc.privateKey = some(parsedPk)
    ethRpc.defaultAccount =
      ethRpc.privateKey.get().toPublicKey().toCanonicalAddress().Address

  let registryAddress = web3.fromHex(web3.Address, g.ethContractAddress)
  let registryContract = ethRpc.contractSender(WakuRlnRegistry, registryAddress)

  # get the current storage index
  var usingStorageIndex: Uint16
  g.retryWrapper(usingStorageIndex, "Failed to get the storage index"):
    await registryContract.usingStorageIndex().call()

  g.usingStorageIndex = some(usingStorageIndex)
  var rlnContractAddress: Address
  g.retryWrapper(rlnContractAddress, "Failed to get the rln contract address"):
    await registryContract.storages(usingStorageIndex).call()
  let rlnContract = ethRpc.contractSender(RlnStorage, rlnContractAddress)

  g.ethRpc = some(ethRpc)
  g.rlnContract = some(rlnContract)
  g.registryContract = some(registryContract)

  if g.keystorePath.isSome() and g.keystorePassword.isSome():
    if not fileExists(g.keystorePath.get()):
      error "File provided as keystore path does not exist", path = g.keystorePath.get()
      return err("File provided as keystore path does not exist")

    var keystoreQuery = KeystoreMembership(
      membershipContract:
        MembershipContract(chainId: $g.chainId.get(), address: g.ethContractAddress)
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
    when defined(rln_v2):
      g.userMessageLimit = some(keystoreCred.userMessageLimit)
    # now we check on the contract if the commitment actually has a membership
    try:
      let membershipExists = await rlnContract
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
    if metadata.chainId != uint64(g.chainId.get()):
      return err("persisted data: chain id mismatch")

    if metadata.contractAddress != g.ethContractAddress.toLower():
      return err("persisted data: contract address mismatch")
    g.latestProcessedBlock = metadata.lastProcessedBlock
    g.validRoots = metadata.validRoots.toDeque()

  # check if the contract exists by calling a static function
  var membershipFee: Uint256
  g.retryWrapper(membershipFee, "Failed to get the membership deposit"):
    await rlnContract.MEMBERSHIP_DEPOSIT().call()
  g.membershipFee = some(membershipFee)

  var deployedBlockNumber: Uint256
  g.retryWrapper(deployedBlockNumber, "Failed to get the deployed block number"):
    await rlnContract.deployedBlockNumber().call()
  debug "using rln storage", deployedBlockNumber, rlnContractAddress
  g.rlnContractDeployedBlockNumber = cast[BlockNumber](deployedBlockNumber)
  g.latestProcessedBlock = max(g.latestProcessedBlock, g.rlnContractDeployedBlockNumber)

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

method stop*(g: OnchainGroupManager): Future[void] {.async, gcsafe.} =
  g.blockFetchingActive = false

  if g.ethRpc.isSome():
    g.ethRpc.get().ondisconnect = nil
    await g.ethRpc.get().close()
  let flushed = g.rlnInstance.flush()
  if not flushed:
    error "failed to flush to the tree db"

  g.initialized = false

proc isSyncing*(g: OnchainGroupManager): Future[bool] {.async, gcsafe.} =
  let ethRpc = g.ethRpc.get()

  var syncing: JsonNode
  g.retryWrapper(syncing, "Failed to get the syncing status"):
    await ethRpc.provider.eth_syncing()
  return syncing.getBool()

method isReady*(g: OnchainGroupManager): Future[bool] {.async.} =
  initializedGuard(g)

  if g.ethRpc.isNone():
    return false

  var currentBlock: BlockNumber
  g.retryWrapper(currentBlock, "Failed to get the current block number"):
    cast[BlockNumber](await g.ethRpc.get().provider.eth_blockNumber())

  # the node is still able to process messages if it is behind the latest block by a factor of the valid roots
  if u256(g.latestProcessedBlock) < (u256(currentBlock) - u256(g.validRoots.len)):
    return false

  return not (await g.isSyncing())
