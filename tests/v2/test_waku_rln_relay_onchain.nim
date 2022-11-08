
# contains rln-relay tests that require interaction with Ganache i.e., onchain tests
{.used.}

import
  std/[options, osproc, streams, strutils],
  testutils/unittests, chronos, chronicles, stint, web3, json,
  stew/byteutils, stew/shims/net as stewNet,
  libp2p/crypto/crypto,
  eth/keys,
  ../../waku/v2/protocol/waku_rln_relay/[waku_rln_relay_utils,
      waku_rln_relay_constants,
      waku_rln_relay_types, 
      rln_relay_contract],
  ../../waku/v2/node/waku_node,
  ../test_helpers,
  ./test_utils

from posix import kill, SIGINT

const RlnRelayPubsubTopic = "waku/2/rlnrelay/proto"
const RlnRelayContentTopic = "waku/2/rlnrelay/proto"

#  contract ABI
contract(MembershipContract):
  proc register(pubkey: Uint256) # external payable
  proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])

#  a util function used for testing purposes
#  it deploys membership contract on Ganache (or any Eth client available on EthClient address)
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
    hasherReceipt = await web3.deployContract(PoseidonHasherCode)
    hasherAddress = hasherReceipt.contractAddress.get
  debug "hasher address: ", hasherAddress


  # encode membership contract inputs to 32 bytes zero-padded
  let
    membershipFeeEncoded = encode(MembershipFee).data
    depthEncoded = encode(MerkleTreeDepth.u256).data
    hasherAddressEncoded = encode(hasherAddress).data
    # this is the contract constructor input
    contractInput = membershipFeeEncoded & depthEncoded & hasherAddressEncoded


  debug "encoded membership fee: ", membershipFeeEncoded
  debug "encoded depth: ", depthEncoded
  debug "encoded hasher address: ", hasherAddressEncoded
  debug "encoded contract input:", contractInput

  # deploy membership contract with its constructor inputs
  let receipt = await web3.deployContract(MembershipContractCode,
      contractInput = contractInput)
  var contractAddress = receipt.contractAddress.get
  debug "Address of the deployed membership contract: ", contractAddress

  balance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
  debug "Account balance after the contract deployment: ", balance

  await web3.close()
  debug "disconnected from ", ethClientAddress

  return contractAddress


proc createEthAccount(): Future[(keys.PrivateKey, Address)] {.async.} =
  let theRNG = keys.newRng()

  let web3 = await newWeb3(EthClient)
  let accounts = await web3.provider.eth_accounts()
  let gasPrice = int(await web3.provider.eth_gasPrice())
  web3.defaultAccount = accounts[0]

  let pk = keys.PrivateKey.random(theRNG[])
  let acc = Address(toCanonicalAddress(pk.toPublicKey()))

  var tx: EthSend
  tx.source = accounts[0]
  tx.value = some(ethToWei(10.u256))
  tx.to = some(acc)
  tx.gasPrice = some(gasPrice)

  # Send 10 eth to acc
  discard await web3.send(tx)
  var balance = await web3.provider.eth_getBalance(acc, "latest")
  assert(balance == ethToWei(10.u256))

  return (pk, acc)


# Installs Ganache Daemon
proc installGanache() =
  # We install Ganache. 
  # Packages will be installed to the ./build folder through the --prefix option
  let installGanache = startProcess("npm", args = ["install",  "ganache", "--prefix", "./build"], options = {poUsePath})
  let returnCode = installGanache.waitForExit()
  debug "Ganache install log", returnCode=returnCode, log=installGanache.outputstream.readAll()

# Uninstalls Ganache Daemon
proc uninstallGanache() =
  # We uninstall Ganache
  # Packages will be uninstalled from the ./build folder through the --prefix option.
  # Passed option is
  # --save: Package will be removed from your dependencies.
  # See npm documentation https://docs.npmjs.com/cli/v6/commands/npm-uninstall for further details
  let uninstallGanache = startProcess("npm", args = ["uninstall",  "ganache", "--save", "--prefix", "./build"], options = {poUsePath})
  let returnCode = uninstallGanache.waitForExit()
  debug "Ganache uninstall log", returnCode=returnCode, log=uninstallGanache.outputstream.readAll()

# Runs Ganache daemon
proc runGanache(): Process =
  # We run directly "node node_modules/ganache/dist/node/cli.js" rather than using "npx ganache", so that the daemon does not spawn in a new child process. 
  # In this way, we can directly send a SIGINT signal to the corresponding PID to gracefully terminate Ganache without dealing with multiple processes.
  # Passed options are
  # --port                            Port to listen on.
  # --miner.blockGasLimit             Sets the block gas limit in WEI.
  # --wallet.defaultBalance           The default account balance, specified in ether.
  # See ganache documentation https://www.npmjs.com/package/ganache for more details
  let runGanache = startProcess("node", args = ["./build/node_modules/ganache/dist/node/cli.js", "--port", "8540", "--miner.blockGasLimit", "300000000000000", "--wallet.defaultBalance", "10000"], options = {poUsePath})
  let ganachePID = runGanache.processID

  # We read stdout from Ganache to see when daemon is ready
  var ganacheStartLog: string
  var cmdline: string
  while true:
    if runGanache.outputstream.readLine(cmdline):
      ganacheStartLog.add cmdline
      if cmdline.contains("Listening on 127.0.0.1:8540"):
        break
  debug "Ganache daemon is running and ready", pid=ganachePID, startLog=ganacheStartLog
  return runGanache


# Stops Ganache daemon
proc stopGanache(runGanache: Process) =

  let ganachePID = runGanache.processID

  # We gracefully terminate Ganache daemon by sending a SIGINT signal to the runGanache PID to trigger RPC server termination and clean-up
  let returnCodeSIGINT = kill(ganachePID.int32, SIGINT)
  debug "Sent SIGINT to Ganache", ganachePID=ganachePID, returnCode=returnCodeSIGINT

  # We wait the daemon to exit
  let returnCodeExit = runGanache.waitForExit()
  debug "Ganache daemon terminated", returnCode=returnCodeExit
  debug "Ganache daemon run log", log=runGanache.outputstream.readAll()

procSuite "Waku-rln-relay":

  ################################
  ## Installing/running Ganache
  ################################

  # We install Ganache
  installGanache()

  # We run Ganache
  let runGanache = runGanache()

  asyncTest "event subscription":
    # preparation ------------------------------
    debug "ethereum client address", EthClient
    let contractAddress = await uploadRLNContract(EthClient)
    # connect to the eth client
    let web3 = await newWeb3(EthClient)
    debug "web3 connected to", EthClient

    # fetch the list of registered accounts
    let accounts = await web3.provider.eth_accounts()
    web3.defaultAccount = accounts[1]
    debug "contract deployer account address ",
        defaultAccount = web3.defaultAccount

    # prepare a contract sender to interact with it
    let contractObj = web3.contractSender(MembershipContract,
        contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require: 
      rlnInstance.isOk() 
    # generate the membership keys
    let membershipKeyPairRes = membershipKeyGen(rlnInstance.get())
    require: 
      membershipKeyPairRes.isOk()
    let membershipKeyPair = membershipKeyPairRes.get()
    let pk =  membershipKeyPair.idCommitment.toUInt256()
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
    let tx = await contractObj.register(pk).send(value = MembershipFee)
    debug "a member is registered", tx = tx

    # wait for the event to be received
    await fut

    # release resources -----------------------
    await web3.close()
  asyncTest "dynamic group management":
    # preparation ------------------------------
    debug "ethereum client address", EthClient
    let contractAddress = await uploadRLNContract(EthClient)
    # connect to the eth client
    let web3 = await newWeb3(EthClient)
    debug "web3 connected to", EthClient

    # fetch the list of registered accounts
    let accounts = await web3.provider.eth_accounts()
    web3.defaultAccount = accounts[1]
    debug "contract deployer account address ",
        defaultAccount = web3.defaultAccount

    # prepare a contract sender to interact with it
    let contractObj = web3.contractSender(MembershipContract,
        contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # test ------------------------------
    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require: 
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    let keyPairRes = rln.membershipKeyGen()
    require: 
      keyPairRes.isOk()
    let keypair = keyPairRes.get()
    let pk = keyPair.idCommitment.toUInt256()
    debug "membership commitment key", pk = pk

    # initialize the WakuRLNRelay
    let rlnPeer = WakuRLNRelay(membershipKeyPair: keyPair,
      membershipIndex: MembershipIndex(0),
      ethClientAddress: EthClient,
      ethAccountAddress: some(accounts[0]),
      membershipContractAddress: contractAddress,
      rlnInstance: rln)

    # generate another membership key pair
    let keyPair2Res = rln.membershipKeyGen()
    require: 
      keyPair2Res.isOk()
    let keyPair2 = keyPair2Res.get()
    let pk2 = keyPair2.idCommitment.toUInt256()
    debug "membership commitment key", pk2 = pk2

    var events = [newFuture[void](), newFuture[void]()]
    proc handler(pubkey: Uint256, index: Uint256): RlnRelayResult[void] =
      debug "handler is called", pubkey = pubkey, index = index
      if pubkey == pk:
        events[0].complete()
      if pubkey == pk2:
        events[1].complete()
      let isSuccessful = rlnPeer.rlnInstance.insertMember(pubkey.toIDCommitment())
      check:
        isSuccessful
      return ok()
    
    # mount the handler for listening to the contract events
    await subscribeToGroupEvents(ethClientUri = EthClient,
                                 ethAccountAddress = some(accounts[0]),
                                 contractAddress = contractAddress,
                                 blockNumber = "0x0",
                                 handler = handler)

    # register a member to the contract
    let tx = await contractObj.register(pk).send(value = MembershipFee)
    debug "a member is registered", tx = tx

    # register another member to the contract
    let tx2 = await contractObj.register(pk2).send(value = MembershipFee)
    debug "a member is registered", tx2 = tx2

    # wait for all the events to be received by the rlnPeer
    await all(events)

    # release resources -----------------------
    await web3.close()

  asyncTest "insert a key to the membership contract":
    # preparation ------------------------------
    debug "ethereum client address", EthClient
    let contractAddress = await uploadRLNContract(EthClient)
    # connect to the eth client
    let web3 = await newWeb3(EthClient)
    debug "web3 connected to", EthClient

    # fetch the list of registered accounts
    let accounts = await web3.provider.eth_accounts()
    web3.defaultAccount = accounts[1]
    let add = web3.defaultAccount
    debug "contract deployer account address ", add

    # prepare a contract sender to interact with it
    let sender = web3.contractSender(MembershipContract,
        contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # send takes the following parameters, c: ContractCallBase, value = 0.u256, gas = 3000000'u64 gasPrice = 0
    # should use send proc for the contract functions that update the state of the contract
    let tx = await sender.register(20.u256).send(value = MembershipFee) # value is the membership fee
    debug "The hash of registration tx: ", tx 

    # var members: array[2, uint256] = [20.u256, 21.u256]
    # debug "This is the batch registration result ", await sender.registerBatch(members).send(value = (members.len * MembershipFee)) # value is the membership fee

    let balance = await web3.provider.eth_getBalance(web3.defaultAccount, "latest")
    debug "Balance after registration: ", balance

    await web3.close()
    debug "disconnected from", EthClient

  asyncTest "registration procedure":
    # preparation ------------------------------
    # deploy the contract
    let contractAddress = await uploadRLNContract(EthClient)

    # prepare rln-relay peer inputs
    let
      web3 = await newWeb3(EthClient)
    await web3.close()

    # create an RLN instance
    let rlnInstance = createRLNInstance()
    require: 
      rlnInstance.isOk()

    # generate the membership keys
    let membershipKeyPairRes = membershipKeyGen(rlnInstance.get())
    require: 
      membershipKeyPairRes.isOk()
    let membershipKeyPair = membershipKeyPairRes.get()

    # create an Ethereum private key and the corresponding account 
    let (ethPrivKey, ethacc) = await createEthAccount()

    # test ------------------------------
    # initialize the WakuRLNRelay
    let rlnPeer = WakuRLNRelay(membershipKeyPair: membershipKeyPair,
      membershipIndex: MembershipIndex(0),
      ethClientAddress: EthClient,
      ethAccountPrivateKey: some(ethPrivKey),
      ethAccountAddress: some(ethacc),
      membershipContractAddress: contractAddress)

    # register the rln-relay peer to the membership contract
    let isSuccessful = await rlnPeer.register()
    check: 
      isSuccessful.isOk()


  asyncTest "mounting waku rln-relay: check correct Merkle tree construction in the static/off-chain group management":
    # preparation ------------------------------
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60110))
    await node.start()

    # create current peer's pk
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()
    # generate a key pair
    let keyPairRes = rln.membershipKeyGen()
    require:
      keyPairRes.isOk()

    let keyPair = keyPairRes.get()
    # current peer index in the Merkle tree
    let index = uint(5)

    # Create a group of 10 members
    var group = newSeq[IDCommitment]()
    for i in 0..10:
      var memberAdded: bool = false
      if (uint(i) == index):
        #  insert the current peer's pk
        group.add(keyPair.idCommitment)
        memberAdded = rln.insertMember(keyPair.idCommitment)
        doAssert(memberAdded)
        debug "member key", key = keyPair.idCommitment.inHex
      else:
        let memberKeyPairRes = rln.membershipKeyGen()
        require:
          memberKeyPairRes.isOk()
        let memberKeyPair = memberKeyPairRes.get()
        group.add(memberKeyPair.idCommitment)
        let memberAdded = rln.insertMember(memberKeyPair.idCommitment)
        require:
          memberAdded
        debug "member key", key = memberKeyPair.idCommitment.inHex

    let expectedRoot = rln.getMerkleRoot().value().inHex
    debug "expected root ", expectedRoot

    # test ------------------------------
    # start rln-relay
    await node.mountRelay(@[RlnRelayPubsubTopic])
    let mountRes = node.mountRlnRelayStatic(group = group,
                            memKeyPair = keyPair,
                            memIndex = index,
                            pubsubTopic = RlnRelayPubsubTopic,
                            contentTopic = RlnRelayContentTopic)
    
    require:
      mountRes.isOk()

    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().inHex
    debug "calculated root ", calculatedRoot

    check:
      expectedRoot == calculatedRoot

    await node.stop()
  
  asyncTest "mounting waku rln-relay: check correct Merkle tree construction in the dynamic/onchain group management":
    # preparation ------------------------------
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60111))
    await node.start()

    # deploy the contract
    let contractAddress = await uploadRLNContract(EthClient)

    # prepare rln-relay inputs
    let
      web3 = await newWeb3(EthClient)
      accounts = await web3.provider.eth_accounts()
      # choose one of the existing accounts for the rln-relay peer
      ethAccountAddress = accounts[0]
    web3.defaultAccount = accounts[0]
    
  

    # create an rln instance
    let rlnInstance = createRLNInstance()
    require:
      rlnInstance.isOk()
    let rln = rlnInstance.get()

    # create two rln key pairs
    let 
      keyPair1Res = rln.membershipKeyGen()
      keyPair2Res = rln.membershipKeyGen()
    require: 
      keyPair1Res.isOk()
      keyPair2Res.isOk()

    let
      keyPair1 = keyPair1Res.get()
      keyPair2 = keyPair2Res.get()
      pk1 = keyPair1.idCommitment.toUInt256() 
      pk2 = keyPair2.idCommitment.toUInt256() 
    debug "member key1", key = keyPair1.idCommitment.inHex
    debug "member key2", key = keyPair2.idCommitment.inHex

    # add the rln keys to the Merkle tree
    let
      memberIsAdded1 = rln.insertMember(keyPair1.idCommitment)
      memberIsAdded2 = rln.insertMember(keyPair2.idCommitment)
    
    require:
      memberIsAdded1
      memberIsAdded2
    
    #  get the Merkle root
    let expectedRoot = rln.getMerkleRoot().value().inHex
    
    # prepare a contract sender to interact with it
    let contractObj = web3.contractSender(MembershipContract,
      contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # register the members to the contract
    let tx1Hash = await contractObj.register(pk1).send(value = MembershipFee)
    debug "a member is registered", tx1 = tx1Hash

    # register another member to the contract
    let tx2Hash = await contractObj.register(pk2).send(value = MembershipFee)
    debug "a member is registered", tx2 = tx2Hash

     # create an Ethereum private key and the corresponding account 
    let (ethPrivKey, ethacc) = await createEthAccount()


    # test ------------------------------
    # start rln-relay
    await node.mountRelay(@[RlnRelayPubsubTopic])
    discard await node.mountRlnRelayDynamic(ethClientAddr = EthClient,
                            ethAccountAddress = some(ethacc),
                            ethAccountPrivKeyOpt = some(ethPrivKey),
                            memContractAddr = contractAddress, 
                            memKeyPair = some(keyPair1),
                            memIndex = some(MembershipIndex(0)),
                            pubsubTopic = RlnRelayPubsubTopic,
                            contentTopic = RlnRelayContentTopic)
    
    await sleepAsync(2000) # wait for the event to reach the group handler

    # rln pks are inserted into the rln peer's Merkle tree and the resulting root
    # is expected to be the same as the calculatedRoot i.e., the one calculated outside of the mountRlnRelayDynamic proc
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().inHex
    debug "calculated root ", calculatedRoot=calculatedRoot
    debug "expected root ", expectedRoot=expectedRoot

    check:
      expectedRoot == calculatedRoot  


    await web3.close()
    await node.stop()

  asyncTest "mounting waku rln-relay: check correct registration of peers without rln-relay credentials in dynamic/on-chain mode":
    # deploy the contract
    let contractAddress = await uploadRLNContract(EthClient)

    # prepare rln-relay inputs
    let
      web3 = await newWeb3(EthClient)
      accounts = await web3.provider.eth_accounts()
      # choose two of the existing accounts for the rln-relay peers
      ethAccountAddress1 = accounts[0]
      ethAccountAddress2 = accounts[1]
    await web3.close()

    # prepare two nodes
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60112))
    await node.start()

    let
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60113))
    await node2.start()

     # create an Ethereum private key and the corresponding account 
    let (ethPrivKey, ethacc) = await createEthAccount()

    # start rln-relay on the first node, leave rln-relay credentials empty
    await node.mountRelay(@[RlnRelayPubsubTopic])
    discard await node.mountRlnRelayDynamic(ethClientAddr = EthClient,
                            ethAccountAddress = some(ethacc),
                            ethAccountPrivKeyOpt = some(ethPrivKey),
                            memContractAddr = contractAddress, 
                            memKeyPair = none(MembershipKeyPair),
                            memIndex = none(MembershipIndex),
                            pubsubTopic = RlnRelayPubsubTopic,
                            contentTopic = RlnRelayContentTopic)
    


    # start rln-relay on the second node, leave rln-relay credentials empty
    await node2.mountRelay(@[RlnRelayPubsubTopic])
    discard await node2.mountRlnRelayDynamic(ethClientAddr = EthClient,
                            ethAccountAddress = some(ethacc),
                            ethAccountPrivKeyOpt = some(ethPrivKey),
                            memContractAddr = contractAddress, 
                            memKeyPair = none(MembershipKeyPair),
                            memIndex = none(MembershipIndex),
                            pubsubTopic = RlnRelayPubsubTopic,
                            contentTopic = RlnRelayContentTopic)

    # the two nodes should be registered into the contract 
    # since nodes are spun up sequentially
    # the first node has index 0 whereas the second node gets index 1
    check:
      node.wakuRlnRelay.membershipIndex == MembershipIndex(0)
      node2.wakuRlnRelay.membershipIndex == MembershipIndex(1)

    await node.stop()
    await node2.stop()

  ################################
  ## Terminating/removing Ganache
  ################################

  # We stop Ganache daemon
  stopGanache(runGanache)

  # We uninstall Ganache
  uninstallGanache()