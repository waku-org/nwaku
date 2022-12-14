import 
    ../group_manager_base

type
    RlnContractWithSender = Sender[RlnContract]
    OnchainGroupManagerConfig* = object
        ethClientUrl*: string
        ethPrivateKey*: Option[string]
        ethContractAddress*: string
        ethRpc: Option[web3]
        rlnContract: Option[RlnContractWithSender]
        membershipFee: Option[Uint256]

    OnchainGroupManager* = ref object of GroupManager[OnchainGroupManagerConfig]

template initializedGuard*(g: OnchainGroupManager): untyped =
    if not g.initialized:
        return err("OnchainGroupManager is not initialized")

method init*(g: OnchainGroupManager): Result[void] {.async.} =
    var web3: Web3
    var contract: RlnContractWithSender
    # check if the Ethereum client is reachable
    try:
        web3 = some(await newWeb3(ethClientAddress))
    except:
        return err("could not connect to the Ethereum client")

    contract = some(web3.contractSender(RlnContract, g.config.ethContractAddress))

    # check if the contract exists by calling a static method
    var membershipFee: uint64
    try:
        membershipFee = await contract.MEMBERSHIP_DEPOSIT()
    except:
        return err("could not get the membership deposit")

    if g.config.ethPrivateKey.isSome():
        let pk = g.config.ethPrivateKey.get()
        web3.privateKey = pk

    g.config.ethRpc = some(web3)
    g.config.rlnContract = some(contract)
    g.config.membershipFee = some(membershipFee)
    
    g.initialized = true
    return ok()

method startGroupSync*(g: OnchainGroupManager): Result[void] {.async.} =
    initializedGuard(g)

    if g.config.ethPrivateKey.isSome():
        # TODO: use register() after generating credentials
        debug "registering commitment on contract"
        await g.register(g.config.idCredentials)

    # TODO: set up the contract event listener and block listener

    
method register*(g: OnchainGroupManager, idCommitment: IDCommitment): Result[void] {.async.} =
    initializedGuard(g)

    let memberInserted = g.rlnInstance.insertMember(idCommitment)
    if not memberInserted:
        return err("Failed to insert member into the merkle tree")

    if g.onRegisterCb.isSome():
        await g.onRegisterCb.get()(@[idCommitment])

    return ok()

method register*(g: OnchainGroupManager, identityCredentials: IdentityCredentials): Result[void] {.async.} =
    initializedGuard(g)

    # TODO: interact with the contract
    let ethRpc = g.config.ethRpc.get()
    let rlnContract = g.config.rlnContract.get()
    let membershipFee = g.config.membershipFee.get()

    let gasPrice = int(await ethRpc.provider.eth_gasPrice()) * 2
    let idCommitment = identityCredentials.idCommitment.toUInt256()
    
    var txHash: TxHash
    try: # send the registration transaction and check if any error occurs
        txHash = await rlnContract.register(pk).send(value = membershipFee, gasPrice = gasPrice)
    except ValueError as e:
        return err("registration transaction failed: " & e.msg)

    let tsReceipt = await ethRpc.getMinedTransactionReceipt(txHash)

    # the receipt topic holds the hash of signature of the raised events
    # TODO: make this robust. search within the event list for the event
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
        eventIndex =  UInt256.fromBytesBE(argumentsBytes[32..^1])

    # don't handle member insertion into the tree here, it will be handled by the event listener
    return ok()

method withdraw*(g: OnchainGroupManager, idCommitment: IDCommitment): Result[void] {.async.} =
    initializedGuard(g)

    # TODO: after slashing is enabled on the contract

method withdrawBatch*(g: OnchainGroupManager, idCommitments: seq[IDCommitment]): Result[void] {.async.} =
    initializedGuard(g)

    # TODO: after slashing is enabled on the contract