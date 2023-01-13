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
  sequtils
import
  ../../rln,
  ../../conversion_utils,
  ../group_manager_base

from strutils import parseHexInt

export group_manager_base

logScope:
  topics = "waku rln_relay onchain_group_manager"

# membership contract interface
contract(RlnContract):
  proc register(pubkey: Uint256) {.payable.} # external payable
  proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}
  proc MEMBERSHIP_DEPOSIT(): Uint256
  # TODO the following are to be supported
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])

type
  RlnContractWithSender = Sender[RlnContract]
  OnchainGroupManagerConfig* = object
    ethClientUrl*: string
    ethPrivateKey*: Option[string]
    ethContractAddress*: string
    ethRpc*: Option[Web3]
    rlnContract*: Option[RlnContractWithSender]
    membershipFee*: Option[Uint256]
    membershipIndex*: Option[MembershipIndex]
    latestProcessedBlock*: Option[BlockNumber]

  OnchainGroupManager* = ref object of GroupManager[OnchainGroupManagerConfig]

template initializedGuard*(g: OnchainGroupManager): untyped =
  if not g.initialized:
    raise newException(ValueError, "OnchainGroupManager is not initialized")

proc register*(g: OnchainGroupManager, idCommitment: IDCommitment): Future[void] {.async.} =
  initializedGuard(g)

  let memberInserted = g.rlnInstance.insertMember(idCommitment)
  if not memberInserted:
    raise newException(ValueError,"member insertion failed")

  if g.registerCb.isSome():
    await g.registerCb.get()(@[Membership(idCommitment: idCommitment, index: g.latestIndex)])

  g.latestIndex += 1

  return

proc registerBatch*(g: OnchainGroupManager, idCommitments: seq[IDCommitment]): Future[void] {.async.} =
  initializedGuard(g)

  let membersInserted = g.rlnInstance.insertMembers(g.latestIndex, idCommitments)
  if not membersInserted:
    raise newException(ValueError, "Failed to insert members into the merkle tree")

  if g.registerCb.isSome():
    var membersSeq = newSeq[Membership]()
    for i in 0 ..< idCommitments.len():
      var index = g.latestIndex + MembershipIndex(i)
      debug "registering member", idCommitment = idCommitments[i], index = index, latestIndex = g.latestIndex
      let member = Membership(idCommitment: idCommitments[i], index: index)
      membersSeq.add(member)
    await g.registerCb.get()(membersSeq)

  g.latestIndex += MembershipIndex(idCommitments.len())

  return

proc register*(g: OnchainGroupManager, identityCredentials: IdentityCredential): Future[void] {.async.} =
  initializedGuard(g)

  let ethRpc = g.config.ethRpc.get()
  let rlnContract = g.config.rlnContract.get()
  let membershipFee = g.config.membershipFee.get()

  let gasPrice = int(await ethRpc.provider.eth_gasPrice()) * 2
  let idCommitment = identityCredentials.idCommitment.toUInt256()

  var txHash: TxHash
  try: # send the registration transaction and check if any error occurs
    txHash = await rlnContract.register(idCommitment).send(value = membershipFee,
                                                           gasPrice = gasPrice)
  except ValueError as e:
    raise newException(ValueError, "could not register the member: " & e.msg)

  let tsReceipt = await ethRpc.getMinedTransactionReceipt(txHash)

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

  g.config.membershipIndex = some(eventIndex.toMembershipIndex())

  # don't handle member insertion into the tree here, it will be handled by the event listener
  return

proc withdraw*(g: OnchainGroupManager, idCommitment: IDCommitment): Future[void] {.async.} =
  initializedGuard(g)

    # TODO: after slashing is enabled on the contract

proc withdrawBatch*(g: OnchainGroupManager, idCommitments: seq[IDCommitment]): Future[void] {.async.} =
  initializedGuard(g)

    # TODO: after slashing is enabled on the contract

proc parseEvent*(event: type MemberRegistered,
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
  except:
    return err("failed to parse the data field of the MemberRegistered event")

type BlockTable* = OrderedTable[BlockNumber, seq[Membership]]

proc getEvents*(g: OnchainGroupManager, fromBlock: BlockNumber, toBlock: Option[BlockNumber] = none(BlockNumber)): Future[BlockTable] {.async.} =
  initializedGuard(g)

  let ethRpc = g.config.ethRpc.get()
  let rlnContract = g.config.rlnContract.get()

  var normalizedToBlock: BlockNumber
  if toBlock.isSome():
    var value = toBlock.get()
    if value == 0:
      # set to latest block
      value = cast[BlockNumber](await ethRpc.provider.eth_blockNumber())
    normalizedToBlock = value
  else:
    normalizedToBlock = fromBlock

  var blockTable = default(BlockTable)
  let events = await rlnContract.getJsonLogs(MemberRegistered, fromBlock = some(fromBlock.blockId()), toBlock = some(normalizedToBlock.blockId()))
  if events.len == 0:
    debug "no events found"
    return blockTable

  for event in events:
    let blockNumber = parseHexInt(event["blockNumber"].getStr()).uint
    let parsedEventRes = parseEvent(MemberRegistered, event)
    if parsedEventRes.isErr():
      error "failed to parse the MemberRegistered event", error=parsedEventRes.error()
      raise newException(ValueError, "failed to parse the MemberRegistered event")
    let parsedEvent = parsedEventRes.get()

    if blockTable.hasKey(blockNumber):
      blockTable[blockNumber].add(parsedEvent)
    else:
      blockTable[blockNumber] = @[parsedEvent]

  return blockTable

proc seedBlockTableIntoTree*(g: OnchainGroupManager, blockTable: BlockTable): Future[void] {.async.} =
  initializedGuard(g)

  for blockNumber, members in blockTable.pairs():
    let latestIndex = g.latestIndex
    let startingIndex = members[0].index
    try:
      await g.registerBatch(members.mapIt(it.idCommitment))
    except:
      error "failed to insert members into the tree"
      raise newException(ValueError, "failed to insert members into the tree")
    debug "new members added to the Merkle tree", commitments=members.mapIt(it.idCommitment.inHex()) , startingIndex=startingIndex
    let lastIndex = startingIndex + members.len.uint - 1
    let indexGap = startingIndex - latestIndex
    if not (toSeq(startingIndex..lastIndex) == members.mapIt(it.index)):
      raise newException(ValueError, "membership indices are not sequential")
    if indexGap != 1.uint and lastIndex != latestIndex:
      warn "membership index gap, may have lost connection", lastIndex, currIndex=latestIndex, indexGap = indexGap
    g.config.latestProcessedBlock = some(blockNumber)

  return

proc getEventsAndSeedIntoTree*(g: OnchainGroupManager, fromBlock: BlockNumber, toBlock: Option[BlockNumber] = none(BlockNumber)): Future[void] {.async.} =
  initializedGuard(g)

  let events = await g.getEvents(fromBlock, toBlock)
  await g.seedBlockTableIntoTree(events)
  return

proc getNewHeadCallback*(g: OnchainGroupManager): BlockHeaderHandler =
  proc newHeadCallback(blockheader: BlockHeader) {.gcsafe.} =
      let latestBlock = blockheader.number.uint
      debug "block received", blockNumber = latestBlock
      # get logs from the last block
      try:
        asyncSpawn g.getEventsAndSeedIntoTree(latestBlock)
      except CatchableError:
        warn "failed to handle log: ", error=getCurrentExceptionMsg()
  return newHeadCallback

proc newHeadErrCallback(error: CatchableError) =
  warn "failed to get new head", error=error.msg

proc startListeningToEvents*(g: OnchainGroupManager): Future[void] {.async.} =
  initializedGuard(g)

  let ethRpc = g.config.ethRpc.get()
  let newHeadCallback = g.getNewHeadCallback()
  try:
    discard await ethRpc.subscribeForBlockHeaders(newHeadCallback, newHeadErrCallback)
  except:
    raise newException(ValueError, "failed to subscribe to block headers: " & getCurrentExceptionMsg())

proc startOnchainSync*(g: OnchainGroupManager, fromBlock: BlockNumber = BlockNumber(0)): Future[void] {.async.} =
  initializedGuard(g)

  try:
    await g.getEventsAndSeedIntoTree(fromBlock, some(fromBlock))
  except:
    raise newException(ValueError, "failed to get the history/reconcile missed blocks: " & getCurrentExceptionMsg())

  # listen to blockheaders and contract events
  try:
    await g.startListeningToEvents()
  except:
    raise newException(ValueError, "failed to start listening to events: " & getCurrentExceptionMsg())

proc startGroupSync*(g: OnchainGroupManager): Future[void] {.async.} =
  initializedGuard(g)
  # Get archive history
  try:
    await startOnchainSync(g)
  except:
    raise newException(ValueError, "failed to start onchain sync service: " & getCurrentExceptionMsg())

  if g.config.ethPrivateKey.isSome() and g.idCredentials.isSome():
    debug "registering commitment on contract"
    await g.register(g.idCredentials.get())

  return

proc onRegister*(g: OnchainGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  g.registerCb = some(cb)

proc onWithdraw*(g: OnchainGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  g.withdrawCb = some(cb)

proc init*(g: OnchainGroupManager): Future[void] {.async.} =
  var ethRpc: Web3
  var contract: RlnContractWithSender
  # check if the Ethereum client is reachable
  try:
    ethRpc = await newWeb3(g.config.ethClientUrl)
  except:
    raise newException(ValueError, "could not connect to the Ethereum client")

  let contractAddress = web3.fromHex(web3.Address, g.config.ethContractAddress)
  contract = ethRpc.contractSender(RlnContract, contractAddress)

  # check if the contract exists by calling a static function
  var membershipFee: Uint256
  try:
    membershipFee = await contract.MEMBERSHIP_DEPOSIT().call()
  except:
    raise newException(ValueError, "could not get the membership deposit")

  if g.config.ethPrivateKey.isSome():
    let pk = string(g.config.ethPrivateKey.get())
    let pkParseRes = keys.PrivateKey.fromHex(pk)
    if pkParseRes.isErr():
      raise newException(ValueError, "could not parse the private key")
    ethRpc.privateKey = some(pkParseRes.get())

  g.config.ethRpc = some(ethRpc)
  g.config.rlnContract = some(contract)
  g.config.membershipFee = some(membershipFee)


  ethRpc.ondisconnect = proc() =
    error "Ethereum client disconnected"
    let fromBlock = g.config.latestProcessedBlock.get()
    info "reconnecting with the Ethereum client, and restarting group sync", fromBlock = fromBlock
    try:
      asyncSpawn g.startOnchainSync(fromBlock)
    except:
      error "failed to restart group sync"

  g.initialized = true
