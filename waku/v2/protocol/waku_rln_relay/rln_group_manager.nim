{.push raises: [Defect].}

import
  std/times,
  chronicles, options, chronos, stint,
  web3, json,
  eth/keys,
  stew/[byteutils],
  group_manager,
  rln, 
  rln_types

logScope:
  topics = "waku rln_relay"


const MembershipFee* = 1000000000000000.u256
type GroupUpdateHandler* = proc(pubkey: Uint256, index: Uint256): GroupManagerResult[void] {.gcsafe, raises: [Defect].}


type OnChainRlnGroupManager* = ref object of GroupManager
    membershipContractAddress*: Address
    ethClientAddress*: string
    ethAccountAddressOpt*: Option[Address]
    # this field is required for signing transactions
    ethAccountPrivateKeyOpt*: Option[PrivateKey]
    memberInsertionHandler: UpdateHandler
    memberDeletionHandler: UpdateHandler
    registrationHandler: Option[RegistrationHandler]
    lastProcessedBlock: string 
    

# membership contract interface
contract(MembershipContract):
  proc register(pubkey: Uint256) # external payable
  proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}
  # TODO the followings are to be supported
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])

# Utils ========================
proc toUInt256*(idCommitment: IDCommitment): UInt256 =
  let pk = UInt256.fromBytesLE(idCommitment)
  return pk

proc toIDCommitment*(idCommitmentUint: UInt256): IDCommitment =
  let pk = IDCommitment(idCommitmentUint.toBytesLE())
  return pk


proc toMembershipIndex*(v: UInt256): MembershipIndex =
  let membershipIndex: MembershipIndex = cast[MembershipIndex](v)
  return membershipIndex

proc subscribeToMemberRegistrations(web3: Web3, 
                                    contractAddress: Address,
                                    fromBlock: string = "0x0",
                                    handler: UpdateHandler): Future[Subscription] {.async, gcsafe.} =
  ## subscribes to member registrations, on a given membership group contract
  ## `fromBlock` indicates the block number from which the subscription starts
  ## `handler` is a callback that is called when a new member is registered
  ## the callback is called with the pubkey and the index of the new member
  ## TODO: need a similar proc for member deletions
  var contractObj = web3.contractSender(MembershipContract, contractAddress)

  let onMemberRegistered = proc (pubkey: Uint256, index: Uint256) {.gcsafe.} =
    debug "onRegister", pubkey = pubkey, index = index
    let idComm = pubkey.toIDCommitment()
    let memIndex = toMembershipIndex(index)
    let updateRes = handler(idComm, memIndex)
    if updateRes.isErr():
      error "Error handling new member registration", err=updateRes.error()

  let onError = proc (err: CatchableError) =
    error "Error in subscription", err=err.msg

  return await contractObj.subscribe(MemberRegistered,
                                     %*{"fromBlock": fromBlock, "address": contractAddress},
                                     onMemberRegistered,
                                     onError)

proc subscribeToGroupEvents*(ethClientUri: string,
                            ethAccountAddressOpt: Option[Address] = none(Address),
                            contractAddress: Address,
                            blockNumber: string = "0x0",
                            memberInsertionHandler: UpdateHandler, 
                            memberDeletionHandler: UpdateHandler) {.async, gcsafe.} = 
  ## connects to the eth client whose URI is supplied as `ethClientUri`
  ## subscribes to the `MemberRegistered` event emitted from the `MembershipContract` which is available on the supplied `contractAddress`
  ## it collects all the events starting from the given `blockNumber`
  ## for every received event, it calls the `handler`
  ## 
  echo "subscribeToGroupEvents"
  let web3 = await newWeb3(ethClientUri)
  var latestBlock: Quantity
  let newHeadCallback = proc (blockheader: BlockHeader) {.gcsafe.} =
    latestBlock = blockheader.number
    debug "block received", blockNumber = latestBlock
  let newHeadErrorHandler = proc (err: CatchableError) {.gcsafe.} =
    error "Error from subscription: ", err=err.msg
  discard await web3.subscribeForBlockHeaders(newHeadCallback, newHeadErrorHandler)

  proc startSubscription(web3: Web3) {.async, gcsafe.} =
    # subscribe to the MemberRegistered events
    # TODO: can do similarly for deletion events, though it is not yet supported
    # TODO: add block number for reconnection logic
    discard await subscribeToMemberRegistrations(web3 = web3,
                                                 contractAddress = contractAddress,
                                                 handler = memberInsertionHandler)
  
  await startSubscription(web3)
  web3.onDisconnect = proc() =
    debug "connection to ethereum node dropped", lastBlock = latestBlock


proc register*(idComm: IDCommitment, 
              ethAccountAddress: Option[Address], 
              ethAccountPrivateKey: keys.PrivateKey, 
              ethClientAddress: string, 
              membershipContractAddress: Address, 
              registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)): Future[GroupManagerResult[MembershipIndex]] {.async.} =
  # TODO may need to also get eth Account Private Key as PrivateKey
  ## registers the idComm  into the membership contract whose address is in rlnPeer.membershipContractAddress
  echo "register is called"
  var web3: Web3
  try: # check if the Ethereum client is reachable
    web3 = await newWeb3(ethClientAddress)
  except:
    return err("could not connect to the Ethereum client")

  if ethAccountAddress.isSome():
    web3.defaultAccount = ethAccountAddress.get()
  # set the account private key
  web3.privateKey = some(ethAccountPrivateKey)
  #  set the gas price twice the suggested price in order for the fast mining
  let gasPrice = int(await web3.provider.eth_gasPrice()) * 2
  
  # when the private key is set in a web3 instance, the send proc (sender.register(pk).send(MembershipFee))
  # does the signing using the provided key
  # web3.privateKey = some(ethAccountPrivateKey)
  var sender = web3.contractSender(MembershipContract, membershipContractAddress) # creates a Sender object with a web3 field and contract address of type Address

  debug "registering an id commitment", idComm=idComm.inHex
  let pk = idComm.toUInt256()

  var txHash: TxHash
  try: # send the registration transaction and check if any error occurs
    txHash = await sender.register(pk).send(value = MembershipFee, gasPrice = gasPrice)
  except ValueError as e:
    return err("registration transaction failed: " & e.msg)

  let tsReceipt = await web3.getMinedTransactionReceipt(txHash)
  
  # the receipt topic holds the hash of signature of the raised events
  let firstTopic = tsReceipt.logs[0].topics[0]
  # the hash of the signature of MemberRegistered(uint256,uint256) event is equal to the following hex value
  if firstTopic[0..65] != "0x5a92c2530f207992057b9c3e544108ffce3beda4a63719f316967c49bf6159d2":
    return err("invalid event signature hash")

  # the arguments of the raised event i.e., MemberRegistered are encoded inside the data field
  # data = pk encoded as 256 bits || index encoded as 256 bits
  let arguments = tsReceipt.logs[0].data
  debug "tx log data", arguments=arguments
  let 
    argumentsBytes = arguments.hexToSeqByte()
    # In TX log data, uints are encoded in big endian
    eventIdCommUint = UInt256.fromBytesBE(argumentsBytes[0..31])
    eventIndex =  UInt256.fromBytesBE(argumentsBytes[32..^1])
    eventIdComm = eventIdCommUint.toIDCommitment()
  debug "the identity commitment key extracted from tx log", eventIdComm=eventIdComm.inHex
  debug "the index of registered identity commitment key", eventIndex=eventIndex

  if eventIdComm != idComm:
    return err("invalid id commitment key")

  await web3.close()

  if registrationHandler.isSome():
    let handler = registrationHandler.get
    handler(toHex(txHash))
  return ok(toMembershipIndex(eventIndex))


# implementation of GroupManager interface ==========

method setEventsHandlers*(gManager: OnChainRlnGroupManager, memberInsertionHandler: UpdateHandler, memberDeletionHandler: UpdateHandler): GroupManagerResult[void] =
  gManager.memberInsertionHandler = memberInsertionHandler
  gManager.memberDeletionHandler = memberDeletionHandler
  return ok()

method start*(gManager: OnChainRlnGroupManager) {.async, gcsafe.}  = 
  echo "start group manager is called"
  await subscribeToGroupEvents(ethClientUri = gManager.ethClientAddress, 
                                ethAccountAddressOpt = gManager.ethAccountAddressOpt, 
                                contractAddress = gManager.membershipContractAddress,
                                blockNumber = gManager.lastProcessedBlock,
                                memberInsertionHandler = gManager.memberInsertionHandler,
                                memberDeletionHandler = gManager.memberDeletionHandler)

method stop*(gManager: OnChainRlnGroupManager): GroupManagerResult[void] = discard             

method setRegistrationHandler*(gManager: OnChainRlnGroupManager, registrationHanlder: Option[RegistrationHandler]): GroupManagerResult[void] =
  gManager.registrationHandler = registrationHanlder
  return ok()

method register*(gManager: OnChainRlnGroupManager, idComm: IDCommitment): Future[GroupManagerResult[MembershipIndex]] {.async, gcsafe.} = 
  echo "register is called"
  if isNone(gManager.ethAccountPrivateKeyOpt):
    echo "cannot register: no eth private key is available"
    debug "cannot register: no eth private key is available"
    return err("cannot register: no eth private key is available")
  let ethAccountPrivateKey = gManager.ethAccountPrivateKeyOpt.get()
  echo "private key is retrieved"  
  let regResult = await register(idComm = idComm, 
                                ethAccountAddress = gManager.ethAccountAddressOpt, 
                                ethAccountPrivateKey = ethAccountPrivateKey, 
                                ethClientAddress = gManager.ethClientAddress, 
                                membershipContractAddress = gManager.membershipContractAddress, 
                                registrationHandler = gManager.registrationHandler)
  if regResult.isErr:
    return err(regResult.error())
  return ok(regResult.get())
