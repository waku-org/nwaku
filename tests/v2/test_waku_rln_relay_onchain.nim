
{.used.}

import
  std/options, sequtils, times,
  testutils/unittests, chronos, chronicles, stint, web3, json,
  stew/byteutils, stew/shims/net as stewNet,
  libp2p/crypto/crypto,
  ../../waku/v2/protocol/waku_rln_relay/[rln, waku_rln_relay_utils, waku_rln_relay_types],
  ../../waku/v2/node/wakunode2,
  ../test_helpers,
  ./test_utils

const RLNRELAY_PUBSUB_TOPIC = "waku/2/rlnrelay/proto"
const RLNRELAY_CONTENT_TOPIC = "waku/2/rlnrelay/proto"

# POSEIDON_HASHER_CODE holds the bytecode of Poseidon hasher solidity smart contract: 
# https://github.com/kilic/rlnapp/blob/master/packages/contracts/contracts/crypto/PoseidonHasher.sol 
# the solidity contract is compiled separately and the resultant bytecode is copied here
const POSEIDON_HASHER_CODE = readFile("tests/v2/poseidonHasher.txt")
# MEMBERSHIP_CONTRACT_CODE contains the bytecode of the membership solidity smart contract:
# https://github.com/kilic/rlnapp/blob/master/packages/contracts/contracts/RLN.sol
# the solidity contract is compiled separately and the resultant bytecode is copied here
const MEMBERSHIP_CONTRACT_CODE = readFile("tests/v2/membershipContract.txt")

# the membership contract code in solidity
# uint256 public immutable MEMBERSHIP_DEPOSIT;
# 	uint256 public immutable DEPTH;
# 	uint256 public immutable SET_SIZE;
# 	uint256 public pubkeyIndex = 0;
# 	mapping(uint256 => uint256) public members;
# 	IPoseidonHasher public poseidonHasher;

# 	event MemberRegistered(uint256 indexed pubkey, uint256 indexed index);
# 	event MemberWithdrawn(uint256 indexed pubkey, uint256 indexed index);

# 	constructor(
# 		uint256 membershipDeposit,
# 		uint256 depth,
# 		address _poseidonHasher
# 	) public {
# 		MEMBERSHIP_DEPOSIT = membershipDeposit;
# 		DEPTH = depth;
# 		SET_SIZE = 1 << depth;
# 		poseidonHasher = IPoseidonHasher(_poseidonHasher);
# 	}

# 	function register(uint256 pubkey) external payable {
# 		require(pubkeyIndex < SET_SIZE, "RLN, register: set is full");
# 		require(msg.value == MEMBERSHIP_DEPOSIT, "RLN, register: membership deposit is not satisfied");
# 		_register(pubkey);
# 	}

# 	function registerBatch(uint256[] calldata pubkeys) external payable {
# 		require(pubkeyIndex + pubkeys.length <= SET_SIZE, "RLN, registerBatch: set is full");
# 		require(msg.value == MEMBERSHIP_DEPOSIT * pubkeys.length, "RLN, registerBatch: membership deposit is not satisfied");
# 		for (uint256 i = 0; i < pubkeys.length; i++) {
# 			_register(pubkeys[i]);
# 		}
# 	}

# 	function withdrawBatch(
# 		uint256[] calldata secrets,
# 		uint256[] calldata pubkeyIndexes,
# 		address payable[] calldata receivers
# 	) external {
# 		uint256 batchSize = secrets.length;
# 		require(batchSize != 0, "RLN, withdrawBatch: batch size zero");
# 		require(batchSize == pubkeyIndexes.length, "RLN, withdrawBatch: batch size mismatch pubkey indexes");
# 		require(batchSize == receivers.length, "RLN, withdrawBatch: batch size mismatch receivers");
# 		for (uint256 i = 0; i < batchSize; i++) {
# 			_withdraw(secrets[i], pubkeyIndexes[i], receivers[i]);
# 		}
# 	}

# 	function withdraw(
# 		uint256 secret,
# 		uint256 _pubkeyIndex,
# 		address payable receiver
# 	) external {
# 		_withdraw(secret, _pubkeyIndex, receiver);
# 	}

contract(Faucet):
  proc withdraw(amount: Uint256) # external payable 
  proc Withdraw(address: Address, amount: Uint256) {.event.}

contract(RLNContract):
  proc register(pubkey: Uint256) # external payable
  proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}


# contract(MembershipContract):
#   proc register(pubkey: Uint256) # external payable
#   # proc registerBatch(pubkeys: seq[Uint256]) # external payable
#   # TODO will add withdraw function after integrating the keyGeneration function (required to compute public keys from secret keys)
#   # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
#   # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])
#   proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}

proc uploadContract*(ethClientAddress: string): Future[Address] {.async.} =
  let web3 = await newWeb3(ethClientAddress)
  debug "web3 connected to", ethClientAddress

  # fetch the list of registered accounts
  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]
  let add =web3.defaultAccount 
  debug "contract deployer account address ", add

  var balance = await web3.provider.eth_getBalance(web3.defaultAccount , "latest")
  debug "Initial account balance: ", balance

  # deploy the poseidon hash first
  let 
    hasherReceipt = await web3.deployContract(POSEIDON_HASHER_CODE)
    hasherAddress = hasherReceipt.contractAddress.get
  debug "hasher address: ", hasherAddress
  

  # encode membership contract inputs to 32 bytes zero-padded
  let 
    membershipFeeEncoded = encode(MembershipFee).data 
    depthEncoded = encode(MERKLE_TREE_DEPTH.u256).data 
    hasherAddressEncoded = encode(hasherAddress).data
    # this is the contract constructor input
    contractInput = membershipFeeEncoded & depthEncoded & hasherAddressEncoded


  debug "encoded membership fee: ", membershipFeeEncoded
  debug "encoded depth: ", depthEncoded
  debug "encoded hasher address: ", hasherAddressEncoded
  debug "encoded contract input:" , contractInput

  # deploy membership contract with its constructor inputs
  let receipt = await web3.deployContract(MEMBERSHIP_CONTRACT_CODE, contractInput = contractInput)
  var contractAddress = receipt.contractAddress.get
  debug "Address of the deployed membership contract: ", contractAddress

  # balance = await web3.provider.eth_getBalance(web3.defaultAccount , "latest")
  # debug "Account balance after the contract deployment: ", balance

  await web3.close()
  debug "disconnected from ", ethClientAddress

  return contractAddress

procSuite "Waku rln relay":
  # asyncTest  "event subscription":
  #   debug "ethereum client address", ETH_CLIENT
  #   let contractAddress = await uploadContract(ETH_CLIENT)
  #   # connect to the eth client
  #   let web3 = await newWeb3(ETH_CLIENT)
  #   debug "web3 connected to", ETH_CLIENT 

  #   # fetch the list of registered accounts
  #   let accounts = await web3.provider.eth_accounts()
  #   web3.defaultAccount = accounts[1]
  #   debug "contract deployer account address ", defaultAccount=web3.defaultAccount 

  #   # prepare a contract sender to interact with it
  #   var contractObj = web3.contractSender(MembershipContract, contractAddress) # creates a Sender object with a web3 field and contract address of type Address

  #   # let notifFut = newFuture[void]()
  #   # var notificationsReceived = 0
  #   var fut = newFuture[void]()

  #   let s = await contractObj.subscribe(MemberRegistered, %*{"fromBlock": "0x0"}) do(
  #     pubkey: Uint256, index: Uint256){.raises: [Defect], gcsafe.}:
  #     try:
  #      echo "onDeposit"
  #      echo "public key", pubkey
  #      echo "index", index
  #      fut.complete()
  #     except Exception as err:
  #       # chronos still raises exceptions which inherit directly from Exception
  #       doAssert false, err.msg
  #   do (err: CatchableError):
  #       echo "Error from DepositEvent subscription: ", err.msg

  #   discard await contractObj.register(20.u256).send(value = MembershipFee)

  #   await fut
  #   await web3.close()
  
  # asyncTest  "event subscription faucet":
    # debug "ethereum client address", ETH_CLIENT
    # # let contractAddress = await uploadContract(ETH_CLIENT)
    # # connect to the eth client
    # let web3 = await newWeb3(ETH_CLIENT)
    # debug "web3 connected to", ETH_CLIENT 

    # # fetch the list of registered accounts
    # let accounts = await web3.provider.eth_accounts()
    # web3.defaultAccount = accounts[2]
    # debug "contract deployer account address ", defaultAccount=web3.defaultAccount 

    # # prepare a contract sender to interact with it
    # var contractObj = web3.contractSender(Faucet, Address("0x51AC2D3E52dE957477dE32dA5892E07C01915d90".hexToByteArray(20))) # creates a Sender object with a web3 field and contract address of type Address
    # echo "create obj done"

    # var fut = newFuture[void]()
    # # int count = 0;

    # let s = await contractObj.subscribe(Withdraw, %*{"fromBlock": "0x0"}) do(
    #   address: Address, amount: Uint256){.raises: [Defect], gcsafe.}:
    #   try:
    #    echo "onDeposit"
    #    echo "address", address
    #    echo "amount", amount
    #   #  fut.complete()
    #   except Exception as err:
    #     # chronos still raises exceptions which inherit directly from Exception
    #     doAssert false, err.msg
    # do (err: CatchableError):
    #     echo "Error from DepositEvent subscription: ", err.msg

    # discard await contractObj.withdraw(0.u256).send()
    # echo "tx sent"

    # await fut
    # await web3.close()

  asyncTest  "event subscription RLN":
    debug "ethereum client address", ETH_CLIENT
    # let contractAddress = await uploadContract(ETH_CLIENT)
    # connect to the eth client
    let web3 = await newWeb3(ETH_CLIENT)
    debug "web3 connected to", ETH_CLIENT 

    # fetch the list of registered accounts
    let accounts = await web3.provider.eth_accounts()
    web3.defaultAccount = accounts[2]
    debug "contract deployer account address ", defaultAccount=web3.defaultAccount 

    # prepare a contract sender to interact with it
    var contractObj = web3.contractSender(RLNContract, Address("0x61AB4d44FF453b66004Ee5c99Ad8286f91D84D75".hexToByteArray(20))) # creates a Sender object with a web3 field and contract address of type Address
    echo "create obj done"

    var fut = newFuture[void]()
    # int count = 0;

    let s = await contractObj.subscribe(MemberRegistered, %*{"fromBlock": "0x0"}) do(
      pubkey: Uint256, index: Uint256){.raises: [Defect], gcsafe.}:
      try:
       echo "onDeposit"
       echo "pubkey", pubkey
       echo "index", index
       fut.complete()
      except Exception as err:
        # chronos still raises exceptions which inherit directly from Exception
        doAssert false, err.msg
    do (err: CatchableError):
        echo "Error from DepositEvent subscription: ", err.msg

    discard await contractObj.register(5.u256).send()
    echo "tx sent"

    await fut
    await web3.close()
    # const invocationsAfter = 1
    # const invocationsBefore = 0

    # let notifFut = newFuture[void]()
    # var notificationsReceived = 0

    # let s = await sender.subscribe(MemberRegistered, %*{"fromBlock": "0x0"}) do (
    #     pubkey: Uint256, index: Uint256) # sender: Address, value: Uint256)
    #     {.raises: [Defect], gcsafe.}:
    #   try:
    #     echo "onEvent: ", pubkey, " value ", index
    #     inc notificationsReceived
    #     echo "notificationsReceived ", notificationsReceived

    #     if notificationsReceived == invocationsBefore + invocationsAfter:
    #       notifFut.complete()
    #   except Exception as err:
    #     # chronos still raises exceptions which inherit directly from Exception
    #     # doAssert false, err.msg
    #     echo "error"
    # do (err: CatchableError):
    #   echo "Error from MyEvent subscription: ", err.msg

    # await notifFut

    # await s.unsubscribe()


    

    # await sleepAsync(6000)

    # send takes three parameters, c: ContractCallBase, value = 0.u256, gas = 3000000'u64 gasPrice = 0 
    # should use send proc for the contract functions that update the state of the contract
    # let tx = await contractObj.register(20.u256).send(value = MembershipFee)
    # debug "The hash of registration tx: ", tx # value is the membership fee
    # await web3.close()
    # debug "disconnected from", ETH_CLIENT

  # asyncTest  "contract membership":
    # debug "ethereum client address", ETH_CLIENT
    # let contractAddress = await uploadContract(ETH_CLIENT)
    # # connect to the eth client
    # let web3 = await newWeb3(ETH_CLIENT)
    # debug "web3 connected to", ETH_CLIENT 

    # # fetch the list of registered accounts
    # let accounts = await web3.provider.eth_accounts()
    # web3.defaultAccount = accounts[1]
    # let add = web3.defaultAccount 
    # debug "contract deployer account address ", add

    # # prepare a contract sender to interact with it
    # var sender = web3.contractSender(MembershipContract, contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # # send takes three parameters, c: ContractCallBase, value = 0.u256, gas = 3000000'u64 gasPrice = 0 
    # # should use send proc for the contract functions that update the state of the contract
    # let tx = await sender.register(20.u256).send(value = MembershipFee)
    # debug "The hash of registration tx: ", tx # value is the membership fee

    # # var members: array[2, uint256] = [20.u256, 21.u256]
    # # debug "This is the batch registration result ", await sender.registerBatch(members).send(value = (members.len * membershipFee)) # value is the membership fee

    # # balance = await web3.provider.eth_getBalance(web3.defaultAccount , "latest")
    # # debug "Balance after registration: ", balance

    # await web3.close()
    # debug "disconnected from", ETH_CLIENT

  # asyncTest "registration procedure":
  #   # deploy the contract
  #   let contractAddress = await uploadContract(ETH_CLIENT)

  #   # prepare rln-relay peer inputs
  #   let 
  #     web3 = await newWeb3(ETH_CLIENT)
  #     accounts = await web3.provider.eth_accounts()
  #     # choose one of the existing accounts for the rln-relay peer  
  #     ethAccountAddress = accounts[9]
  #   await web3.close()

  #   # create an RLN instance
  #   var rlnInstance = createRLNInstance()
  #   check: rlnInstance.isOk == true

  #   # generate the membership keys
  #   let membershipKeyPair = membershipKeyGen(rlnInstance.value)
    
  #   check: membershipKeyPair.isSome

  #   # initialize the WakuRLNRelay 
  #   var rlnPeer = WakuRLNRelay(membershipKeyPair: membershipKeyPair.get(),
  #     membershipIndex: MembershipIndex(0),
  #     ethClientAddress: ETH_CLIENT,
  #     ethAccountAddress: ethAccountAddress,
  #     membershipContractAddress: contractAddress)
    
  #   # register the rln-relay peer to the membership contract
  #   let is_successful = await rlnPeer.register()
  #   check:
  #     is_successful
  # asyncTest "mounting waku rln-relay":
  #   let
  #     nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
  #     node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"),
  #       Port(60000))
  #   await node.start()

  #   # deploy the contract
  #   let membershipContractAddress = await uploadContract(ETH_CLIENT)

  #   # prepare rln-relay inputs
  #   let 
  #     web3 = await newWeb3(ETH_CLIENT)
  #     accounts = await web3.provider.eth_accounts()
  #     # choose one of the existing account for the rln-relay peer  
  #     ethAccountAddress = accounts[9]
  #   await web3.close()

  #   # create current peer's pk
  #   var rlnInstance = createRLNInstance()
  #   check rlnInstance.isOk == true
  #   var rln = rlnInstance.value
  #   # generate a key pair
  #   var keypair = rln.membershipKeyGen()
  #   doAssert(keypair.isSome())

  #   # current peer index in the Merkle tree
  #   let index = uint(5)

  #   # Create a group of 10 members 
  #   var group = newSeq[IDCommitment]()
  #   for i in 0..10:
  #     var member_is_added: bool = false
  #     if (uint(i) == index):
  #       #  insert the current peer's pk
  #       group.add(keypair.get().idCommitment)
  #       member_is_added = rln.insertMember(keypair.get().idCommitment)
  #       doAssert(member_is_added)
  #       debug "member key", key=keypair.get().idCommitment.toHex
  #     else:
  #       var memberKeypair = rln.membershipKeyGen()
  #       doAssert(memberKeypair.isSome())
  #       group.add(memberKeypair.get().idCommitment)
  #       member_is_added = rln.insertMember(memberKeypair.get().idCommitment)
  #       doAssert(member_is_added)
  #       debug "member key", key=memberKeypair.get().idCommitment.toHex
  #   let expectedRoot = rln.getMerkleRoot().value().toHex
  #   debug "expected root ", expectedRoot

  #   # start rln-relay
  #   node.mountRelay(@[RLNRELAY_PUBSUB_TOPIC])
  #   await node.mountRlnRelay(ethClientAddrOpt = some(EthClient), 
  #                           ethAccAddrOpt =  some(ethAccountAddress), 
  #                           memContractAddOpt =  some(membershipContractAddress), 
  #                           groupOpt = some(group), 
  #                           memKeyPairOpt = some(keypair.get()),  
  #                           memIndexOpt = some(index), 
  #                           pubsubTopic = RLNRELAY_PUBSUB_TOPIC,
  #                           contentTopic = RLNRELAY_CONTENT_TOPIC)
  #   let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().toHex
  #   debug "calculated root ", calculatedRoot

  #   check expectedRoot == calculatedRoot

  #   await node.stop()

