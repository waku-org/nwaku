when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  web3,
  web3/ethtypes,
  eth/keys as keys,
  chronicles,
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
  ../group_manager_base

from strutils import parseHexInt

export group_manager_base

logScope:
  topics = "waku rln_relay onchain_group_manager"

# membership contract interface
contract(RlnContract):
  proc register(idCommitment: Uint256) {.payable.} # external payable
  proc MemberRegistered(idCommitment: Uint256, index: Uint256) {.event.}
  proc MEMBERSHIP_DEPOSIT(): Uint256
  # TODO the following are to be supported
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])

type
  RlnContractWithSender = Sender[RlnContract]
  OnchainGroupManager* = ref object of GroupManager
    ethClientUrl*: string
    ethPrivateKey*: Option[string]
    ethContractAddress*: string
    ethRpc*: Option[Web3]
    rlnContract*: Option[RlnContractWithSender]
    membershipFee*: Option[Uint256]
    latestProcessedBlock*: Option[BlockNumber]
    registrationTxHash*: Option[TxHash]
    chainId*: Option[Quantity]
    keystorePath*: Option[string]
    keystoreIndex*: uint
    membershipGroupIndex*: uint
    keystorePassword*: Option[string]
    saveKeystore*: bool
    registrationHandler*: Option[RegistrationHandler]
    # this buffer exists to backfill appropriate roots for the merkle tree,
    # in event of a reorg. we store 5 in the buffer. Maybe need to revisit this,
    # because the average reorg depth is 1 to 2 blocks.
    validRootBuffer*: Deque[MerkleNode]

const DefaultKeyStorePath* = "rlnKeystore.json"
const DefaultKeyStorePassword* = "password"

const DecayFactor* = 1.2
const DefaultChunkSize* = 1000

template initializedGuard(g: OnchainGroupManager): untyped =
  if not g.initialized:
    raise newException(ValueError, "OnchainGroupManager is not initialized")

method atomicBatch*(g: OnchainGroupManager,
                    start: MembershipIndex,
                    idCommitments = newSeq[IDCommitment](),
                    toRemoveIndices = newSeq[MembershipIndex]()): Future[void] {.async.} =
  initializedGuard(g)

  waku_rln_membership_insertion_duration_seconds.nanosecondTime:
    let operationSuccess = g.rlnInstance.atomicWrite(some(start), idCommitments, toRemoveIndices)
  if not operationSuccess:
    raise newException(ValueError, "atomic batch operation failed")
  waku_rln_number_registered_memberships.inc(int64(idCommitments.len - toRemoveIndices.len))

  if g.registerCb.isSome():
    var membersSeq = newSeq[Membership]()
    for i in 0 ..< idCommitments.len():
      var index = start + MembershipIndex(i)
      debug "registering member", idCommitment = idCommitments[i], index = index
      let member = Membership(idCommitment: idCommitments[i], index: index)
      membersSeq.add(member)
    await g.registerCb.get()(membersSeq)

  g.validRootBuffer = g.slideRootQueue()

method register*(g: OnchainGroupManager, idCommitment: IDCommitment): Future[void] {.async.} =
  initializedGuard(g)

  await g.registerBatch(@[idCommitment])



method registerBatch*(g: OnchainGroupManager, idCommitments: seq[IDCommitment]): Future[void] {.async.} =
  initializedGuard(g)

  await g.atomicBatch(g.latestIndex, idCommitments)
  g.latestIndex += MembershipIndex(idCommitments.len())


method register*(g: OnchainGroupManager, identityCredentials: IdentityCredential): Future[void] {.async.} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()
  let rlnContract = g.rlnContract.get()
  let membershipFee = g.membershipFee.get()

  let gasPrice = int(await ethRpc.provider.eth_gasPrice()) * 2
  let idCommitment = identityCredentials.idCommitment.toUInt256()

  var txHash: TxHash
  try: # send the registration transaction and check if any error occurs
    txHash = await rlnContract.register(idCommitment).send(value = membershipFee,
                                                           gasPrice = gasPrice,
                                                           gas = 100000'u64)
  except ValueError as e:
    error "error while registering the member", msg = e.msg
    raise newException(ValueError, "could not register the member: " & e.msg)

  # wait for the transaction to be mined
  let tsReceipt = await ethRpc.getMinedTransactionReceipt(txHash)

  g.registrationTxHash = some(txHash)
  # the receipt topic holds the hash of signature of the raised events
  # TODO: make this robust. search within the event list for the event
  let firstTopic = tsReceipt.logs[0].topics[0]
  # the hash of the signature of MemberRegistered(uint256,uint256) event is equal to the following hex value
  if firstTopic[0..65] != "0x5a92c2530f207992057b9c3e544108ffce3beda4a63719f316967c49bf6159d2":
    raise newException(ValueError, "unexpected event signature")

  # the arguments of the raised event i.e., MemberRegistered are encoded inside the data field
  # data = pk encoded as 256 bits || index encoded as 256 bits
  let arguments = tsReceipt.logs[0].data
  debug "tx log data", arguments=arguments
  let
    argumentsBytes = arguments.hexToSeqByte()
    # In TX log data, uints are encoded in big endian
    eventIndex =  UInt256.fromBytesBE(argumentsBytes[32..^1])

  g.membershipIndex = some(eventIndex.toMembershipIndex())

  # don't handle member insertion into the tree here, it will be handled by the event listener
  return

method withdraw*(g: OnchainGroupManager, idCommitment: IDCommitment): Future[void] {.async.} =
  initializedGuard(g)

    # TODO: after slashing is enabled on the contract

method withdrawBatch*(g: OnchainGroupManager, idCommitments: seq[IDCommitment]): Future[void] {.async.} =
  initializedGuard(g)

    # TODO: after slashing is enabled on the contract, use atomicBatch internally

proc parseEvent(event: type MemberRegistered,
                 log: JsonNode): GroupManagerResult[Membership] =
  ## parses the `data` parameter of the `MemberRegistered` event `log`
  ## returns an error if it cannot parse the `data` parameter
  var idComm: UInt256
  var index: UInt256
  var data: string
  # Remove the 0x prefix
  try:
    data = strip0xPrefix(log["data"].getStr())
  except CatchableError:
    return err("failed to parse the data field of the MemberRegistered event: " & getCurrentExceptionMsg())
  var offset = 0
  try:
    # Parse the idComm
    offset += decode(data, offset, idComm)
    # Parse the index
    offset += decode(data, offset, index)
    return ok(Membership(idCommitment: idComm.toIDCommitment(), index: index.toMembershipIndex()))
  except CatchableError:
    return err("failed to parse the data field of the MemberRegistered event")

type BlockTable* = OrderedTable[BlockNumber, seq[(Membership, bool)]]

proc backfillRootQueue*(g: OnchainGroupManager, len: uint): Future[void] {.async.} =
  if len > 0:
    # backfill the tree's acceptable roots
    for i in 0..len-1:
      # remove the last root
      g.validRoots.popLast()
    for i in 0..len-1:
      # add the backfilled root
      g.validRoots.addLast(g.validRootBuffer.popLast())

proc insert(blockTable: var BlockTable, blockNumber: BlockNumber, member: Membership, removed: bool) =
  let memberTuple = (member, removed)
  if blockTable.hasKeyOrPut(blockNumber, @[memberTuple]):
    try:
      blockTable[blockNumber].add(memberTuple)
    except KeyError: # qed
      error "could not insert member into block table", blockNumber=blockNumber, member=member

proc getRawEvents(g: OnchainGroupManager,
                  fromBlock: BlockNumber,
                  toBlock: Option[BlockNumber] = none(BlockNumber)): Future[JsonNode] {.async.} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()
  let rlnContract = g.rlnContract.get()

  var normalizedToBlock: BlockNumber
  if toBlock.isSome():
    var value = toBlock.get()
    if value == 0:
      # set to latest block
      value = cast[BlockNumber](await ethRpc.provider.eth_blockNumber())
    normalizedToBlock = value
  else:
    normalizedToBlock = fromBlock

  let events =  await rlnContract.getJsonLogs(MemberRegistered,
                                              fromBlock = some(fromBlock.blockId()),
                                              toBlock = some(normalizedToBlock.blockId()))
  return events

proc getBlockTable(g: OnchainGroupManager,
                    fromBlock: BlockNumber,
                    toBlock: Option[BlockNumber] = none(BlockNumber)): Future[BlockTable] {.async.} =
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
      error "failed to parse the MemberRegistered event", error=parsedEventRes.error()
      raise newException(ValueError, "failed to parse the MemberRegistered event")
    let parsedEvent = parsedEventRes.get()
    blockTable.insert(blockNumber, parsedEvent, removed)

  return blockTable

proc handleEvents(g: OnchainGroupManager,
                  blockTable: BlockTable): Future[void] {.async.} =
  initializedGuard(g)

  for blockNumber, members in blockTable.pairs():
    try:
      let startIndex = blockTable[blockNumber].filterIt(not it[1])[0][0].index
      let removalIndices = members.filterIt(it[1]).mapIt(it[0].index)
      let idCommitments = members.mapIt(it[0].idCommitment)
      await g.atomicBatch(start = startIndex,
                          idCommitments = idCommitments,
                          toRemoveIndices = removalIndices)
      g.latestIndex = startIndex + MembershipIndex(idCommitments.len())
    except CatchableError:
      error "failed to insert members into the tree", error=getCurrentExceptionMsg()
      raise newException(ValueError, "failed to insert members into the tree")
    trace "new members added to the Merkle tree", commitments=members.mapIt(it[0].idCommitment.inHex())

  return

proc handleRemovedEvents(g: OnchainGroupManager, blockTable: BlockTable): Future[void] {.async.} =
  initializedGuard(g)

  # count number of blocks that have been removed
  var numRemovedBlocks: uint = 0
  for blockNumber, members in blockTable.pairs():
    if members.anyIt(it[1]):
      numRemovedBlocks += 1

  await g.backfillRootQueue(numRemovedBlocks)

proc setMetadata*(g: OnchainGroupManager): RlnRelayResult[void] =
  if g.latestProcessedBlock.isNone():
    return err("latest processed block is not set")
  try:
    let metadataSetRes = g.rlnInstance.setMetadata(RlnMetadata(
                            lastProcessedBlock: g.latestProcessedBlock.get(),
                            chainId: uint64(g.chainId.get()),
                            contractAddress: g.ethContractAddress))
    if metadataSetRes.isErr():
      return err("failed to persist rln metadata: " & metadataSetRes.error())
  except CatchableError:
    return err("failed to persist rln metadata: " & getCurrentExceptionMsg())
  return ok()

proc getAndHandleEvents(g: OnchainGroupManager,
                        fromBlock: BlockNumber,
                        toBlock: Option[BlockNumber] = none(BlockNumber)): Future[void] {.async.} =
  initializedGuard(g)

  let blockTable = await g.getBlockTable(fromBlock, toBlock)
  await g.handleEvents(blockTable)
  await g.handleRemovedEvents(blockTable)

  let latestProcessedBlock = if toBlock.isSome(): toBlock.get()
                             else: fromBlock
  g.latestProcessedBlock = some(latestProcessedBlock)
  let metadataSetRes = g.setMetadata()
  if metadataSetRes.isErr():
    # this is not a fatal error, hence we don't raise an exception
    warn "failed to persist rln metadata", error=metadataSetRes.error()
  else:
    debug "rln metadata persisted", blockNumber = latestProcessedBlock

proc getNewHeadCallback(g: OnchainGroupManager): BlockHeaderHandler =
  proc newHeadCallback(blockheader: BlockHeader) {.gcsafe.} =
      let latestBlock = blockheader.number.uint
      trace "block received", blockNumber = latestBlock
      # get logs from the last block
      try:
        asyncSpawn g.getAndHandleEvents(latestBlock)
      except CatchableError:
        warn "failed to handle log: ", error=getCurrentExceptionMsg()
  return newHeadCallback

proc newHeadErrCallback(error: CatchableError) =
  warn "failed to get new head", error=error.msg

proc startListeningToEvents(g: OnchainGroupManager): Future[void] {.async.} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()
  let newHeadCallback = g.getNewHeadCallback()
  try:
    discard await ethRpc.subscribeForBlockHeaders(newHeadCallback, newHeadErrCallback)
  except CatchableError:
    raise newException(ValueError, "failed to subscribe to block headers: " & getCurrentExceptionMsg())

proc startOnchainSync(g: OnchainGroupManager): Future[void] {.async.} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()

  # the block chunk size decays exponentially with the number of blocks
  # the minimum chunk size is 100
  var blockChunkSize = 1_000_000

  var fromBlock = if g.latestProcessedBlock.isSome():
    info "resuming onchain sync from block", fromBlock = g.latestProcessedBlock.get()
    g.latestProcessedBlock.get() + 1
  else:
    info "starting onchain sync from scratch"
    BlockNumber(0)

  let latestBlock = cast[BlockNumber](await ethRpc.provider.eth_blockNumber())
  try:
    # we always want to sync from last processed block => latest
    if fromBlock == BlockNumber(0) or
       fromBlock + BlockNumber(blockChunkSize) < latestBlock:
      # chunk events
      while true:
        let currentLatestBlock = cast[BlockNumber](await g.ethRpc.get().provider.eth_blockNumber())
        let toBlock = min(fromBlock + BlockNumber(blockChunkSize), currentLatestBlock)
        info "chunking events", fromBlock = fromBlock, toBlock = toBlock
        await g.getAndHandleEvents(fromBlock, some(toBlock))
        fromBlock = toBlock + 1
        if fromBlock >= currentLatestBlock:
          break
        let newChunkSize = float(blockChunkSize) / DecayFactor
        blockChunkSize = max(int(newChunkSize), DefaultChunkSize)
    else:
      await g.getAndHandleEvents(fromBlock, some(BlockNumber(0)))
  except CatchableError:
    raise newException(ValueError, "failed to get the history/reconcile missed blocks: " & getCurrentExceptionMsg())

  # listen to blockheaders and contract events
  try:
    await g.startListeningToEvents()
  except CatchableError:
    raise newException(ValueError, "failed to start listening to events: " & getCurrentExceptionMsg())

proc persistCredentials(g: OnchainGroupManager): GroupManagerResult[void] =
  if not g.saveKeystore:
    return ok()
  if g.idCredentials.isNone():
    return err("no credentials to persist")

  let index = g.membershipIndex.get()
  let idCredential = g.idCredentials.get()
  var path = DefaultKeystorePath
  var password = DefaultKeystorePassword

  if g.keystorePath.isSome():
    path = g.keystorePath.get()
  else:
    warn "keystore: no credentials path set, using default path", path=DefaultKeystorePath

  if g.keystorePassword.isSome():
    password = g.keystorePassword.get()
  else:
    warn "keystore: no credentials password set, using default password", password=DefaultKeystorePassword

  let keystoreCred = MembershipCredentials(
    identityCredential: idCredential,
    membershipGroups: @[MembershipGroup(
      membershipContract: MembershipContract(
        chainId: $g.chainId.get(),
        address: g.ethContractAddress
      ),
      treeIndex: index
    )]
  )

  let persistRes = addMembershipCredentials(path, @[keystoreCred], password, RLNAppInfo)
  if persistRes.isErr():
    error "keystore: failed to persist credentials", error=persistRes.error()

  return ok()

method startGroupSync*(g: OnchainGroupManager): Future[void] {.async.} =
  initializedGuard(g)
  # Get archive history
  try:
    await startOnchainSync(g)
  except CatchableError:
    raise newException(ValueError, "failed to start onchain sync service: " & getCurrentExceptionMsg())

  if g.ethPrivateKey.isSome() and g.idCredentials.isNone():
    let idCredentialRes = g.rlnInstance.membershipKeyGen()
    if idCredentialRes.isErr():
      raise newException(CatchableError, "Identity credential generation failed")
    let idCredential = idCredentialRes.get()
    g.idCredentials = some(idCredential)

    debug "registering commitment on contract"
    await g.register(idCredential)
    if g.registrationHandler.isSome():
      # We need to callback with the tx hash
      let handler = g.registrationHandler.get()
      handler($g.registrationTxHash.get())

    let persistRes = g.persistCredentials()
    if persistRes.isErr():
      error "failed to persist credentials", error=persistRes.error()

  return

method onRegister*(g: OnchainGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  g.registerCb = some(cb)

method onWithdraw*(g: OnchainGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  g.withdrawCb = some(cb)

method init*(g: OnchainGroupManager): Future[void] {.async.} =
  var ethRpc: Web3
  var contract: RlnContractWithSender
  # check if the Ethereum client is reachable
  try:
    ethRpc = await newWeb3(g.ethClientUrl)
  except CatchableError:
    raise newException(ValueError, "could not connect to the Ethereum client")

  # Set the chain id
  let chainId = await ethRpc.provider.eth_chainId()
  g.chainId = some(chainId)

  if g.ethPrivateKey.isSome():
    let pk = g.ethPrivateKey.get()
    let pkParseRes = keys.PrivateKey.fromHex(pk)
    if pkParseRes.isErr():
      raise newException(ValueError, "could not parse the private key")
    ethRpc.privateKey = some(pkParseRes.get())
    ethRpc.defaultAccount = ethRpc.privateKey.get().toPublicKey().toCanonicalAddress().Address


  let contractAddress = web3.fromHex(web3.Address, g.ethContractAddress)
  contract = ethRpc.contractSender(RlnContract, contractAddress)

  g.ethRpc = some(ethRpc)
  g.rlnContract = some(contract)

  if g.keystorePath.isSome() and g.keystorePassword.isSome():
    waku_rln_membership_credentials_import_duration_seconds.nanosecondTime:
      let parsedCredsRes = getMembershipCredentials(path = g.keystorePath.get(),
                                                    password = g.keystorePassword.get(),
                                                    filterMembershipContracts = @[MembershipContract(chainId: $chainId,
                                                    address: g.ethContractAddress)],
                                                    appInfo = RLNAppInfo)
    if parsedCredsRes.isErr():
      raise newException(ValueError, "could not parse the keystore: " & $parsedCredsRes.error())
    let parsedCreds = parsedCredsRes.get()
    if parsedCreds.len == 0:
      raise newException(ValueError, "keystore is empty")
    g.idCredentials = some(parsedCreds[g.keystoreIndex].identityCredential)
    g.membershipIndex = some(parsedCreds[g.keystoreIndex].membershipGroups[g.membershipGroupIndex].treeIndex)

  let metadataGetRes = g.rlnInstance.getMetadata()
  if metadataGetRes.isErr():
    warn "could not initialize with persisted rln metadata"
    g.latestProcessedBlock = some(BlockNumber(0))
  else:
    let metadata = metadataGetRes.get()
    if metadata.chainId != uint64(g.chainId.get()):
      raise newException(ValueError, "persisted data: chain id mismatch")
  
    if metadata.contractAddress != g.ethContractAddress.toLower():
      raise newException(ValueError, "persisted data: contract address mismatch")
    g.latestProcessedBlock = some(metadata.lastProcessedBlock)

  # check if the contract exists by calling a static function
  var membershipFee: Uint256
  try:
    membershipFee = await contract.MEMBERSHIP_DEPOSIT().call()
  except CatchableError:
    raise newException(ValueError, 
                       "could not get the membership deposit: " & getCurrentExceptionMsg())
  g.membershipFee = some(membershipFee)

  ethRpc.ondisconnect = proc() =
    error "Ethereum client disconnected"
    let fromBlock = g.latestProcessedBlock.get()
    info "reconnecting with the Ethereum client, and restarting group sync", fromBlock = fromBlock
    try:
      asyncSpawn g.startOnchainSync()
    except CatchableError:
      error "failed to restart group sync", error = getCurrentExceptionMsg()

  g.initialized = true

method stop*(g: OnchainGroupManager): Future[void] {.async.} =
  if g.ethRpc.isSome():
    g.ethRpc.get().ondisconnect = nil
    await g.ethRpc.get().close()
  let flushed = g.rlnInstance.flush()
  if not flushed:
    error "failed to flush to the tree db"

  g.initialized = false
