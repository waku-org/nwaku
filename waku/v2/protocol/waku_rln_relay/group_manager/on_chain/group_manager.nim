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
  stew/[byteutils, arrayops],
  sequtils
import
  ../../ffi,
  ../../conversion_utils,
  ../group_manager_base

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
    ethRpc: Option[Web3]
    rlnContract: Option[RlnContractWithSender]
    membershipFee: Option[Uint256]
    membershipIndex: Option[MembershipIndex]

  OnchainGroupManager* = ref object of GroupManager[OnchainGroupManagerConfig]

template initializedGuard*(g: OnchainGroupManager): untyped =
  if not g.initialized:
    raise newException(ValueError, "OnchainGroupManager is not initialized")

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

  g.initialized = true

proc register*(g: OnchainGroupManager, idCommitment: IDCommitment): Future[void] {.async.} =
  initializedGuard(g)

  let memberInserted = g.rlnInstance.insertMember(idCommitment)
  if not memberInserted:
    raise newException(ValueError,"member insertion failed")

  g.latestIndex += 1

  if g.registerCb.isSome():
    await g.registerCb.get()(@[(idCommitment, g.latestIndex)])

  return

proc registerBatch*(g: OnchainGroupManager, idCommitments: seq[IDCommitment]): Future[void] {.async.} =
  initializedGuard(g)

  let membersInserted = g.rlnInstance.insertMembers(g.latestIndex + 1, idCommitments)
  if not membersInserted:
    raise newException(ValueError, "Failed to insert members into the merkle tree")

  g.latestIndex += MembershipIndex(idCommitments.len() - 1)

  let retSeq = idCommitments.mapIt((it, g.latestIndex))
  if g.registerCb.isSome():
    await g.registerCb.get()(retSeq)

  return

proc register*(g: OnchainGroupManager, identityCredentials: IdentityCredential): Future[void] {.async.} =
  initializedGuard(g)

    # TODO: interact with the contract
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

proc startGroupSync*(g: OnchainGroupManager): Future[void] {.async.} =
  initializedGuard(g)

  if g.config.ethPrivateKey.isSome() and g.idCredentials.isSome():
    debug "registering commitment on contract"
    await g.register(g.idCredentials.get())

  # TODO: set up the contract event listener and block listener
