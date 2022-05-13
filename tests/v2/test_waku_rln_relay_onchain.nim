
# contains rln-relay tests that require interaction with Ganache i.e., onchain tests
{.used.}

import
  std/options, sequtils, times,
  testutils/unittests, chronos, chronicles, stint, web3, json,
  stew/byteutils, stew/shims/net as stewNet,
  libp2p/crypto/crypto,
  ../../waku/v2/protocol/waku_rln_relay/[rln, waku_rln_relay_utils,
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
    let pk = membershipKeyPair.get().idCommitment.toUInt256()
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

  asyncTest "mounting waku rln-relay":
    # preparation ------------------------------
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
    await node.start()

    # deploy the contract
    let membershipContractAddress = await uploadRLNContract(ETH_CLIENT)

    # prepare rln-relay inputs
    let
      web3 = await newWeb3(ETH_CLIENT)
      accounts = await web3.provider.eth_accounts()
      # choose one of the existing account for the rln-relay peer
      ethAccountAddress = accounts[9]
    await web3.close()

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
    await node.mountRlnRelay(ethClientAddrOpt = some(EthClient),
                            ethAccAddrOpt = some(ethAccountAddress),
                            memContractAddOpt = some(membershipContractAddress),
                            groupOpt = some(group),
                            memKeyPairOpt = some(keypair.get()),
                            memIndexOpt = some(index),
                            pubsubTopic = RLNRELAY_PUBSUB_TOPIC,
                            contentTopic = RLNRELAY_CONTENT_TOPIC)
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().toHex
    debug "calculated root ", calculatedRoot

    check:
      expectedRoot == calculatedRoot

    await node.stop()

