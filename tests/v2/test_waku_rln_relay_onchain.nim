
# contains rln-relay tests that require interaction with Ganache i.e., onchain tests
{.used.}

import
  std/options,
  testutils/unittests, chronos, chronicles, stint, web3, json,
  stew/byteutils, stew/shims/net as stewNet,
  libp2p/crypto/crypto,
  ../../waku/v2/protocol/waku_rln_relay/[waku_rln_relay_utils,
      waku_rln_relay_types, rln_relay_contract],
  ../../waku/v2/node/wakunode2,
  ../test_helpers,
  ./test_utils

const RLNRELAY_PUBSUB_TOPIC = "waku/2/rlnrelay/proto"
const RLNRELAY_CONTENT_TOPIC = "waku/2/rlnrelay/proto"

#  contract ABI
contract(MembershipContract):
  proc register(pubkey: Uint256) # external payable
  proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])

#  a util function used for testing purposes
#  it deploys membership contract on Ganache (or any Eth client available on ETH_CLIENT address)
#  must be edited if used for a different contract than membership contract
proc uploadRLNContract*(ethClientAddress: string): Future[Address] {.async.} =
  let web3 = await newWeb3(ethClientAddress)
  debug "web3 connected to", ethClientAddress

  # fetch the list of registered accounts
  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]
  let add = web3.defaultAccount
  debug "contract deployer account address ", add

  var balance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Initial account balance: ", balance

  # deploy the poseidon hash contract and gets its address
  let
    hasherReceipt = await web3.deployContract(POSEIDON_HASHER_CODE)
    hasherAddress = hasherReceipt.contractAddress.get
  debug "hasher address: ", hasherAddress


  # encode membership contract inputs to 32 bytes zero-padded
  let
    membershipFeeEncoded = encode(MEMBERSHIP_FEE).data
    depthEncoded = encode(MERKLE_TREE_DEPTH.u256).data
    hasherAddressEncoded = encode(hasherAddress).data
    # this is the contract constructor input
    contractInput = membershipFeeEncoded & depthEncoded & hasherAddressEncoded


  debug "encoded membership fee: ", membershipFeeEncoded
  debug "encoded depth: ", depthEncoded
  debug "encoded hasher address: ", hasherAddressEncoded
  debug "encoded contract input:", contractInput

  # deploy membership contract with its constructor inputs
  let receipt = await web3.deployContract(MEMBERSHIP_CONTRACT_CODE,
      contractInput = contractInput)
  var contractAddress = receipt.contractAddress.get
  debug "Address of the deployed membership contract: ", contractAddress

  balance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Account balance after the contract deployment: ", balance

  await web3.close()
  debug "disconnected from ", ethClientAddress

  return contractAddress

procSuite "Waku-rln-relay":
  asyncTest "event subscription":
    # preparation ------------------------------
    debug "ethereum client address", ETH_CLIENT
    let contractAddress = await uploadRLNContract(ETH_CLIENT)
    # connect to the eth client
    let web3 = await newWeb3(ETH_CLIENT)
    debug "web3 connected to", ETH_CLIENT

    # fetch the list of registered accounts
    let accounts = await web3.provider.eth_accounts()
    web3.defaultAccount = accounts[1]
    debug "contract deployer account address ",
        defaultAccount = web3.defaultAccount

    # prepare a contract sender to interact with it
    var contractObj = web3.contractSender(MembershipContract,
        contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # create an RLN instance
    var rlnInstance = createRLNInstance()
    check: 
      rlnInstance.isOk == true
    # generate the membership keys
    let membershipKeyPair = membershipKeyGen(rlnInstance.value)
    check: 
      membershipKeyPair.isSome
    let pk =  membershipKeyPair.get().idCommitment.toUInt256()
    debug "membership commitment key", pk = pk

    # test ------------------------------
    var fut = newFuture[void]()
    let s = await contractObj.subscribe(MemberRegistered, %*{"fromBlock": "0x0",
        "address": contractAddress}) do(
      pubkey: Uint256, index: Uint256){.raises: [Defect], gcsafe.}:
      try:
        debug "onRegister", pubkey = pubkey, index = index
        check:
          pubkey == pk
        fut.complete()
      except Exception as err:
        # chronos still raises exceptions which inherit directly from Exception
        doAssert false, err.msg
    do (err: CatchableError):
      echo "Error from subscription: ", err.msg

    # register a member
    let tx = await contractObj.register(pk).send(value = MEMBERSHIP_FEE)
    debug "a member is registered", tx = tx

    # wait for the event to be received
    await fut

    # release resources -----------------------
    await web3.close()
  asyncTest "dynamic group management":
    # preparation ------------------------------
    debug "ethereum client address", ETH_CLIENT
    let contractAddress = await uploadRLNContract(ETH_CLIENT)
    # connect to the eth client
    let web3 = await newWeb3(ETH_CLIENT)
    debug "web3 connected to", ETH_CLIENT

    # fetch the list of registered accounts
    let accounts = await web3.provider.eth_accounts()
    web3.defaultAccount = accounts[1]
    debug "contract deployer account address ",
        defaultAccount = web3.defaultAccount

    # prepare a contract sender to interact with it
    var contractObj = web3.contractSender(MembershipContract,
        contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # test ------------------------------
    # create an RLN instance
    var rlnInstance = createRLNInstance()
    check: 
      rlnInstance.isOk == true
    var rln = rlnInstance.value

    let keyPair = rln.membershipKeyGen()
    check: 
      keyPair.isSome
    let pk = keyPair.get().idCommitment.toUInt256()
    debug "membership commitment key", pk = pk

    # initialize the WakuRLNRelay
    var rlnPeer = WakuRLNRelay(membershipKeyPair: keyPair.get(),
      membershipIndex: MembershipIndex(0),
      ethClientAddress: ETH_CLIENT,
      ethAccountAddress: accounts[0],
      membershipContractAddress: contractAddress,
      rlnInstance: rln)

    # generate another membership key pair
    let keyPair2 = rln.membershipKeyGen()
    check: 
      keyPair2.isSome
    let pk2 = keyPair2.get().idCommitment.toUInt256()
    debug "membership commitment key", pk2 = pk2

    var events = [newFuture[void](), newFuture[void]()]
    proc handler(pubkey: Uint256, index: Uint256) =
      debug "handler is called", pubkey = pubkey, index = index
      if pubkey == pk:
        events[0].complete()
      if pubkey == pk2:
        events[1].complete()
      let isSuccessful = rlnPeer.rlnInstance.insertMember(pubkey.toIDCommitment())
      check:
        isSuccessful
    
    # mount the handler for listening to the contract events
    await rlnPeer.handleGroupUpdates(handler)

    # register a member to the contract
    let tx = await contractObj.register(pk).send(value = MEMBERSHIP_FEE)
    debug "a member is registered", tx = tx

    # register another member to the contract
    let tx2 = await contractObj.register(pk2).send(value = MEMBERSHIP_FEE)
    debug "a member is registered", tx2 = tx2

    # wait for all the events to be received by the rlnPeer
    await all(events)

    # release resources -----------------------
    await web3.close()

  asyncTest "insert a key to the membership contract":
    # preparation ------------------------------
    debug "ethereum client address", ETH_CLIENT
    let contractAddress = await uploadRLNContract(ETH_CLIENT)
    # connect to the eth client
    let web3 = await newWeb3(ETH_CLIENT)
    debug "web3 connected to", ETH_CLIENT

    # fetch the list of registered accounts
    let accounts = await web3.provider.eth_accounts()
    web3.defaultAccount = accounts[1]
    let add = web3.defaultAccount
    debug "contract deployer account address ", add

    # prepare a contract sender to interact with it
    var sender = web3.contractSender(MembershipContract,
        contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # send takes the following parameters, c: ContractCallBase, value = 0.u256, gas = 3000000'u64 gasPrice = 0
    # should use send proc for the contract functions that update the state of the contract
    let tx = await sender.register(20.u256).send(value = MEMBERSHIP_FEE) # value is the membership fee
    debug "The hash of registration tx: ", tx 

    # var members: array[2, uint256] = [20.u256, 21.u256]
    # debug "This is the batch registration result ", await sender.registerBatch(members).send(value = (members.len * MEMBERSHIP_FEE)) # value is the membership fee

    let balance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
    debug "Balance after registration: ", balance

    await web3.close()
    debug "disconnected from", ETH_CLIENT

  asyncTest "registration procedure":
    # preparation ------------------------------
    # deploy the contract
    let contractAddress = await uploadRLNContract(ETH_CLIENT)

    # prepare rln-relay peer inputs
    let
      web3 = await newWeb3(ETH_CLIENT)
      accounts = await web3.provider.eth_accounts()
      # choose one of the existing accounts for the rln-relay peer
      ethAccountAddress = accounts[0]
    await web3.close()

    # create an RLN instance
    var rlnInstance = createRLNInstance()
    check: 
      rlnInstance.isOk == true

    # generate the membership keys
    let membershipKeyPair = membershipKeyGen(rlnInstance.value)
    check: 
      membershipKeyPair.isSome

    # test ------------------------------
    # initialize the WakuRLNRelay
    var rlnPeer = WakuRLNRelay(membershipKeyPair: membershipKeyPair.get(),
      membershipIndex: MembershipIndex(0),
      ethClientAddress: ETH_CLIENT,
      ethAccountAddress: ethAccountAddress,
      membershipContractAddress: contractAddress)

    # register the rln-relay peer to the membership contract
    let is_successful = await rlnPeer.register()
    check: 
      is_successful


  asyncTest "mounting waku rln-relay: check correct Merkle tree construction in the static/off-chain group management":
    # preparation ------------------------------
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
    await node.start()

    # create current peer's pk
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value
    # generate a key pair
    var keypair = rln.membershipKeyGen()
    doAssert(keypair.isSome())

    # current peer index in the Merkle tree
    let index = uint(5)

    # Create a group of 10 members
    var group = newSeq[IDCommitment]()
    for i in 0..10:
      var member_is_added: bool = false
      if (uint(i) == index):
        #  insert the current peer's pk
        group.add(keypair.get().idCommitment)
        member_is_added = rln.insertMember(keypair.get().idCommitment)
        doAssert(member_is_added)
        debug "member key", key = keypair.get().idCommitment.toHex
      else:
        var memberKeypair = rln.membershipKeyGen()
        doAssert(memberKeypair.isSome())
        group.add(memberKeypair.get().idCommitment)
        member_is_added = rln.insertMember(memberKeypair.get().idCommitment)
        doAssert(member_is_added)
        debug "member key", key = memberKeypair.get().idCommitment.toHex

    let expectedRoot = rln.getMerkleRoot().value().toHex
    debug "expected root ", expectedRoot

    # test ------------------------------
    # start rln-relay
    node.mountRelay(@[RLNRELAY_PUBSUB_TOPIC])
    node.mountRlnRelayStatic(group = group,
                            memKeyPair = keypair.get(),
                            memIndex = index,
                            pubsubTopic = RLNRELAY_PUBSUB_TOPIC,
                            contentTopic = RLNRELAY_CONTENT_TOPIC)
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().toHex
    debug "calculated root ", calculatedRoot

    check:
      expectedRoot == calculatedRoot

    await node.stop()
  
  asyncTest "mounting waku rln-relay: check correct Merkle tree construction in the dynamic/onchain group management":
    # preparation ------------------------------
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60000))
    await node.start()

    # deploy the contract
    let contractAddress = await uploadRLNContract(ETH_CLIENT)

    # prepare rln-relay inputs
    let
      web3 = await newWeb3(ETH_CLIENT)
      accounts = await web3.provider.eth_accounts()
      # choose one of the existing accounts for the rln-relay peer
      ethAccountAddress = accounts[0]
    web3.defaultAccount = accounts[0]

    # create an rln instance
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value

    # create two rln key pairs
    let 
      keyPair1 = rln.membershipKeyGen()
      keyPair2 = rln.membershipKeyGen()
    check: 
      keyPair1.isSome
      keyPair2.isSome
    let 
      pk1 = keyPair1.get().idCommitment.toUInt256() 
      pk2 = keyPair2.get().idCommitment.toUInt256() 
    debug "member key1", key = keyPair1.get().idCommitment.toHex
    debug "member key2", key = keyPair2.get().idCommitment.toHex

    # add the rln keys to the Merkle tree
    let
      member_is_added1 = rln.insertMember(keyPair1.get().idCommitment)
      member_is_added2 = rln.insertMember(keyPair2.get().idCommitment)
    doAssert(member_is_added1)
    doAssert(member_is_added2)
    
    #  get the Merkle root
    let expectedRoot = rln.getMerkleRoot().value().toHex
    
    # prepare a contract sender to interact with it
    var contractObj = web3.contractSender(MembershipContract,
      contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # register the members to the contract
    let tx1Hash = await contractObj.register(pk1).send(value = MEMBERSHIP_FEE)
    debug "a member is registered", tx1 = tx1Hash

    # register another member to the contract
    let tx2Hash = await contractObj.register(pk2).send(value = MEMBERSHIP_FEE)
    debug "a member is registered", tx2 = tx2Hash

    # test ------------------------------
    # start rln-relay
    node.mountRelay(@[RLNRELAY_PUBSUB_TOPIC])
    await node.mountRlnRelayDynamic(ethClientAddr = EthClient,
                            ethAccAddr = ethAccountAddress,
                            memContractAddr = contractAddress, 
                            memKeyPair = keyPair1,
                            memIndex = some(MembershipIndex(0)),
                            pubsubTopic = RLNRELAY_PUBSUB_TOPIC,
                            contentTopic = RLNRELAY_CONTENT_TOPIC)
    
    await sleepAsync(2000) # wait for the event to reach the group handler

    # rln pks are inserted into the rln peer's Merkle tree and the resulting root
    # is expected to be the same as the calculatedRoot i.e., the one calculated outside of the mountRlnRelayDynamic proc
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().toHex
    debug "calculated root ", calculatedRoot=calculatedRoot
    debug "expected root ", expectedRoot=expectedRoot

    check:
      expectedRoot == calculatedRoot  


    await web3.close()
    await node.stop()

  asyncTest "mounting waku rln-relay: check correct registration of peers without rln-relay credentials in dynamic/on-chain mode":
    # deploy the contract
    let contractAddress = await uploadRLNContract(ETH_CLIENT)

    # prepare rln-relay inputs
    let
      web3 = await newWeb3(ETH_CLIENT)
      accounts = await web3.provider.eth_accounts()
      # choose two of the existing accounts for the rln-relay peers
      ethAccountAddress1 = accounts[0]
      ethAccountAddress2 = accounts[1]
    await web3.close()

    # prepare two nodes
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60000))
    await node.start()

    let
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60001))
    await node2.start()

    # start rln-relay on the first node, leave rln-relay credentials empty
    node.mountRelay(@[RLNRELAY_PUBSUB_TOPIC])
    await node.mountRlnRelayDynamic(ethClientAddr = EthClient,
                            ethAccAddr = ethAccountAddress1,
                            memContractAddr = contractAddress, 
                            memKeyPair = none(MembershipKeyPair),
                            memIndex = none(MembershipIndex),
                            pubsubTopic = RLNRELAY_PUBSUB_TOPIC,
                            contentTopic = RLNRELAY_CONTENT_TOPIC)
    


    # start rln-relay on the second node, leave rln-relay credentials empty
    node2.mountRelay(@[RLNRELAY_PUBSUB_TOPIC])
    await node2.mountRlnRelayDynamic(ethClientAddr = EthClient,
                            ethAccAddr = ethAccountAddress2,
                            memContractAddr = contractAddress, 
                            memKeyPair = none(MembershipKeyPair),
                            memIndex = none(MembershipIndex),
                            pubsubTopic = RLNRELAY_PUBSUB_TOPIC,
                            contentTopic = RLNRELAY_CONTENT_TOPIC)

    # the two nodes should be registered into the contract 
    # since nodes are spun up sequentially
    # the first node has index 0 whereas the second node gets index 1
    check:
      node.wakuRlnRelay.membershipIndex == MembershipIndex(0)
      node2.wakuRlnRelay.membershipIndex == MembershipIndex(1)

    await node.stop()
    await node2.stop()