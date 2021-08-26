
{.used.}

import
  std/options,
  testutils/unittests, chronos, chronicles, stint, web3,
  stew/byteutils, stew/shims/net as stewNet,
  libp2p/crypto/crypto,
  ../../waku/v2/protocol/waku_rln_relay/[rln, waku_rln_relay_utils, waku_rln_relay_types],
  ../../waku/v2/node/wakunode2,
  ../test_helpers,
  ./test_utils


# the address of Ethereum client (ganache-cli for now)
# TODO this address in hardcoded in the code, we may need to take it as input from the user
const EthClient = "ws://localhost:8540/"

# poseidonHasherCode holds the bytecode of Poseidon hasher solidity smart contract: 
# https://github.com/kilic/rlnapp/blob/master/packages/contracts/contracts/crypto/PoseidonHasher.sol 
# the solidity contract is compiled separately and the resultant bytecode is copied here
const poseidonHasherCode = readFile("tests/v2/poseidonHasher.txt")
# membershipContractCode contains the bytecode of the membership solidity smart contract:
# https://github.com/kilic/rlnapp/blob/master/packages/contracts/contracts/RLN.sol
# the solidity contract is compiled separately and the resultant bytecode is copied here
const membershipContractCode = readFile("tests/v2/membershipContract.txt")

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

contract(MembershipContract):
  proc register(pubkey: Uint256) # external payable
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # TODO will add withdraw function after integrating the keyGeneration function (required to compute public keys from secret keys)
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])

proc uploadContract(ethClientAddress: string): Future[Address] {.async.} =
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
    hasherReceipt = await web3.deployContract(poseidonHasherCode)
    hasherAddress = hasherReceipt.contractAddress.get
  debug "hasher address: ", hasherAddress
  

  # encode membership contract inputs to 32 bytes zero-padded
  let 
    membershipFeeEncoded = encode(MembershipFee).data 
    depthEncoded = encode(Depth).data 
    hasherAddressEncoded = encode(hasherAddress).data
    # this is the contract constructor input
    contractInput = membershipFeeEncoded & depthEncoded & hasherAddressEncoded


  debug "encoded membership fee: ", membershipFeeEncoded
  debug "encoded depth: ", depthEncoded
  debug "encoded hasher address: ", hasherAddressEncoded
  debug "encoded contract input:" , contractInput

  # deploy membership contract with its constructor inputs
  let receipt = await web3.deployContract(membershipContractCode, contractInput = contractInput)
  var contractAddress = receipt.contractAddress.get
  debug "Address of the deployed membership contract: ", contractAddress

  # balance = await web3.provider.eth_getBalance(web3.defaultAccount , "latest")
  # debug "Account balance after the contract deployment: ", balance

  await web3.close()
  debug "disconnected from ", ethClientAddress

  return contractAddress

procSuite "Waku rln relay":
  asyncTest  "contract membership":
    let contractAddress = await uploadContract(EthClient)
    # connect to the eth client
    let web3 = await newWeb3(EthClient)
    debug "web3 connected to", EthClient

    # fetch the list of registered accounts
    let accounts = await web3.provider.eth_accounts()
    web3.defaultAccount = accounts[1]
    let add = web3.defaultAccount 
    debug "contract deployer account address ", add

    # prepare a contract sender to interact with it
    var sender = web3.contractSender(MembershipContract, contractAddress) # creates a Sender object with a web3 field and contract address of type Address

    # send takes three parameters, c: ContractCallBase, value = 0.u256, gas = 3000000'u64 gasPrice = 0 
    # should use send proc for the contract functions that update the state of the contract
    let tx = await sender.register(20.u256).send(value = MembershipFee)
    debug "The hash of registration tx: ", tx # value is the membership fee

    # var members: array[2, uint256] = [20.u256, 21.u256]
    # debug "This is the batch registration result ", await sender.registerBatch(members).send(value = (members.len * membershipFee)) # value is the membership fee

    # balance = await web3.provider.eth_getBalance(web3.defaultAccount , "latest")
    # debug "Balance after registration: ", balance

    await web3.close()
    debug "disconnected from", EthClient

  asyncTest "registration procedure":
    # deploy the contract
    let contractAddress = await uploadContract(EthClient)

    # prepare rln-relay peer inputs
    let 
      web3 = await newWeb3(EthClient)
      accounts = await web3.provider.eth_accounts()
      # choose one of the existing accounts for the rln-relay peer  
      ethAccountAddress = accounts[9]
    await web3.close()

    # create an RLN instance
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true

    # generate the membership keys
    let membershipKeyPair = membershipKeyGen(rlnInstance.value)
    
    check:
      membershipKeyPair.isSome

    # initialize the WakuRLNRelay 
    var rlnPeer = WakuRLNRelay(membershipKeyPair: membershipKeyPair.get(),
      membershipIndex: uint(0),
      ethClientAddress: EthClient,
      ethAccountAddress: ethAccountAddress,
      membershipContractAddress: contractAddress)
    
    # register the rln-relay peer to the membership contract
    let is_successful = await rlnPeer.register()
    check:
      is_successful
  asyncTest "mounting waku rln relay":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
    await node.start()

    # deploy the contract
    let membershipContractAddress = await uploadContract(EthClient)

    # prepare rln-relay inputs
    let 
      web3 = await newWeb3(EthClient)
      accounts = await web3.provider.eth_accounts()
      # choose one of the existing account for the rln-relay peer  
      ethAccountAddress = accounts[9]
    await web3.close()

    # create current peer's pk
    var rlnInstance = createRLNInstance(32)
    check rlnInstance.isOk == true
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
        debug "member key", key=keypair.get().idCommitment.toHex
      else:
        var memberKeypair = rln.membershipKeyGen()
        doAssert(memberKeypair.isSome())
        group.add(memberKeypair.get().idCommitment)
        member_is_added = rln.insertMember(memberKeypair.get().idCommitment)
        doAssert(member_is_added)
        debug "member key", key=memberKeypair.get().idCommitment.toHex
    let expectedRoot = rln.getMerkleRoot().value().toHex
    debug "expected root ", expectedRoot

    # start rln-relay
    await node.mountRlnRelay(ethClientAddrOpt = some(EthClient), ethAccAddrOpt =  some(ethAccountAddress), memContractAddOpt =  some(membershipContractAddress), groupOpt = some(group), memKeyPairOpt = some(keypair.get()),  memIndexOpt = some(index))
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().toHex
    debug "calculated root ", calculatedRoot

    check expectedRoot == calculatedRoot

    await node.stop()


suite "Waku rln relay":
  test "key_gen Nim Wrappers":
    var 
      merkleDepth: csize_t = 32
      # parameters.key contains the parameters related to the Poseidon hasher
      # to generate this file, clone this repo https://github.com/kilic/rln 
      # and run the following command in the root directory of the cloned project
      # cargo run --example export_test_keys
      # the file is generated separately and copied here
      parameters = readFile("waku/v2/protocol/waku_rln_relay/parameters.key")
      pbytes = parameters.toBytes()
      len : csize_t = uint(pbytes.len)
      parametersBuffer = Buffer(`ptr`: addr(pbytes[0]), len: len)
    check:
      # check the parameters.key is not empty
      pbytes.len != 0

    var 
      rlnInstance: RLN[Bn256]
    let res = new_circuit_from_params(merkleDepth, addr parametersBuffer, addr rlnInstance)
    check:
      # check whether the circuit parameters are generated successfully
      res == true

    # keysBufferPtr will hold the generated key pairs i.e., secret and public keys 
    var 
      keysBuffer : Buffer
      keysBufferPtr = addr(keysBuffer)
      done = key_gen(rlnInstance, keysBufferPtr) 
    check:
      # check whether the keys are generated successfully
      done == true

    if done:
      var generatedKeys = cast[ptr array[64, byte]](keysBufferPtr.`ptr`)[]
      check:
        # the public and secret keys together are 64 bytes
        generatedKeys.len == 64
      debug "generated keys: ", generatedKeys 
    
  test "membership Key Gen":
    # create an RLN instance
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true

    var key = membershipKeyGen(rlnInstance.value)
    var empty : array[32,byte]
    check:
      key.isSome
      key.get().idKey.len == 32
      key.get().idCommitment.len == 32
      key.get().idKey != empty
      key.get().idCommitment != empty
    
    debug "the generated membership key pair: ", key 

  test "get_root Nim binding":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true

    # read the Merkle Tree root
    var 
      root1 {.noinit.} : Buffer = Buffer()
      rootPtr1 = addr(root1)
      get_root_successful1 = get_root(rlnInstance.value, rootPtr1)
    doAssert(get_root_successful1)
    doAssert(root1.len == 32)

    # read the Merkle Tree root
    var 
      root2 {.noinit.} : Buffer = Buffer()
      rootPtr2 = addr(root2)
      get_root_successful2 = get_root(rlnInstance.value, rootPtr2)
    doAssert(get_root_successful2)
    doAssert(root2.len == 32)

    var rootValue1 = cast[ptr array[32,byte]] (root1.`ptr`)
    let rootHex1 = rootValue1[].toHex

    var rootValue2 = cast[ptr array[32,byte]] (root2.`ptr`)
    let rootHex2 = rootValue2[].toHex

    # the two roots must be identical
    doAssert(rootHex1 == rootHex2)
  test "getMerkleRoot utils":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true

    # read the Merkle Tree root
    var root1 = getMerkleRoot(rlnInstance.value())
    doAssert(root1.isOk)
    let rootHex1 = root1.value().toHex

    # read the Merkle Tree root
    var root2 = getMerkleRoot(rlnInstance.value())
    doAssert(root2.isOk)
    let rootHex2 = root2.value().toHex

    # the two roots must be identical
    doAssert(rootHex1 == rootHex2)

  test "update_next_member Nim Wrapper":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true

    # generate a key pair
    var keypair = membershipKeyGen(rlnInstance.value)
    doAssert(keypair.isSome())
    var pkBuffer = Buffer(`ptr`: addr(keypair.get().idCommitment[0]), len: 32)
    let pkBufferPtr = addr pkBuffer

    # add the member to the tree
    var member_is_added = update_next_member(rlnInstance.value, pkBufferPtr)
    check:
      member_is_added == true
    
  test "delete_member Nim wrapper":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true

    # delete the first member 
    var deleted_member_index = uint(0)
    let deletion_success = delete_member(rlnInstance.value, deleted_member_index)
    doAssert(deletion_success)

  test "insertMember rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value
    # generate a key pair
    var keypair = rln.membershipKeyGen()
    doAssert(keypair.isSome())
    check:
      rln.insertMember(keypair.get().idCommitment)  
    
  test "removeMember rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value
    check: 
      rln.removeMember(uint(0))

  test "Merkle tree consistency check between deletion and insertion":
    # create an RLN instance
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true

    # read the Merkle Tree root
    var 
      root1 {.noinit.} : Buffer = Buffer()
      rootPtr1 = addr(root1)
      get_root_successful1 = get_root(rlnInstance.value, rootPtr1)
    doAssert(get_root_successful1)
    doAssert(root1.len == 32)
    
    # generate a key pair
    var keypair = membershipKeyGen(rlnInstance.value)
    doAssert(keypair.isSome())
    var pkBuffer = Buffer(`ptr`: addr(keypair.get().idCommitment[0]), len: 32)
    let pkBufferPtr = addr pkBuffer

    # add the member to the tree
    var member_is_added = update_next_member(rlnInstance.value, pkBufferPtr)
    doAssert(member_is_added)

    # read the Merkle Tree root after insertion
    var 
      root2 {.noinit.} : Buffer = Buffer()
      rootPtr2 = addr(root2)
      get_root_successful2 = get_root(rlnInstance.value, rootPtr2)
    doAssert(get_root_successful2)
    doAssert(root2.len == 32)

    # delete the first member 
    var deleted_member_index = uint(0)
    let deletion_success = delete_member(rlnInstance.value, deleted_member_index)
    doAssert(deletion_success)

    # read the Merkle Tree root after the deletion
    var 
      root3 {.noinit.} : Buffer = Buffer()
      rootPtr3 = addr(root3)
      get_root_successful3 = get_root(rlnInstance.value, rootPtr3)
    doAssert(get_root_successful3)
    doAssert(root3.len == 32)

    var rootValue1 = cast[ptr array[32,byte]] (root1.`ptr`)
    let rootHex1 = rootValue1[].toHex
    debug "The initial root", rootHex1

    var rootValue2 = cast[ptr array[32,byte]] (root2.`ptr`)
    let rootHex2 = rootValue2[].toHex
    debug "The root after insertion", rootHex2

    var rootValue3 = cast[ptr array[32,byte]] (root3.`ptr`)
    let rootHex3 = rootValue3[].toHex
    debug "The root after deletion", rootHex3

    # the root must change after the insertion
    doAssert(not(rootHex1 == rootHex2))

    ## The initial root of the tree (empty tree) must be identical to 
    ## the root of the tree after one insertion followed by a deletion
    doAssert(rootHex1 == rootHex3)
  test "Merkle tree consistency check between deletion and insertion using rln utils":
    # create an RLN instance
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value()

    # read the Merkle Tree root
    var root1 = rln.getMerkleRoot()
    doAssert(root1.isOk)
    let rootHex1 = root1.value().toHex()
    
    # generate a key pair
    var keypair = rln.membershipKeyGen()
    doAssert(keypair.isSome())
    let member_inserted = rln.insertMember(keypair.get().idCommitment) 
    check member_inserted

    # read the Merkle Tree root after insertion
    var root2 = rln.getMerkleRoot()
    doAssert(root2.isOk)
    let rootHex2 = root2.value().toHex()

  
    # delete the first member 
    var deleted_member_index = uint(0)
    let deletion_success = rln.removeMember(deleted_member_index)
    doAssert(deletion_success)

    # read the Merkle Tree root after the deletion
    var root3 = rln.getMerkleRoot()
    doAssert(root3.isOk)
    let rootHex3 = root3.value().toHex()


    debug "The initial root", rootHex1
    debug "The root after insertion", rootHex2
    debug "The root after deletion", rootHex3

    # the root must change after the insertion
    doAssert(not(rootHex1 == rootHex2))

    ## The initial root of the tree (empty tree) must be identical to 
    ## the root of the tree after one insertion followed by a deletion
    doAssert(rootHex1 == rootHex3)

  test "hash Nim Wrappers":
    # create an RLN instance
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true
    
    # prepare the input
    var
      hashInput : array[32, byte]
    for x in hashInput.mitems: x= 1
    var 
      hashInputHex = hashInput.toHex()
      hashInputBuffer = Buffer(`ptr`: addr hashInput[0], len: 32 ) 

    debug "sample_hash_input_bytes", hashInputHex

    # prepare other inputs to the hash function
    var 
      outputBuffer: Buffer
      numOfInputs = 1.uint # the number of hash inputs that can be 1 or 2
    
    let hashSuccess = hash(rlnInstance.value, addr hashInputBuffer, numOfInputs, addr outputBuffer)
    doAssert(hashSuccess)
    let outputArr = cast[ptr array[32,byte]](outputBuffer.`ptr`)[]
    doAssert("53a6338cdbf02f0563cec1898e354d0d272c8f98b606c538945c6f41ef101828" == outputArr.toHex())

    var 
      hashOutput = cast[ptr array[32,byte]] (outputBuffer.`ptr`)[]
      hashOutputHex = hashOutput.toHex()

    debug "hash output", hashOutputHex

  test "generate_proof and verify Nim Wrappers":
    # create an RLN instance

    # check if the rln instance is created successfully 
    var rlnInstance = createRLNInstance(32)
    check:
      rlnInstance.isOk == true


    # create the membership key
    var auth = membershipKeyGen(rlnInstance.value)
    var skBuffer = Buffer(`ptr`: addr(auth.get().idKey[0]), len: 32)

    # peer's index in the Merkle Tree
    var index = 5

    # prepare the authentication object with peer's index and sk
    var authObj: Auth = Auth(secret_buffer: addr skBuffer, index: uint(index))

    # Create a Merkle tree with random members 
    for i in 0..10:
      var member_is_added: bool = false
      if (i == index):
        #  insert the current peer's pk
        var pkBuffer = Buffer(`ptr`: addr(auth.get().idCommitment[0]), len: 32)
        member_is_added = update_next_member(rlnInstance.value, addr pkBuffer)
      else:
        var memberKeys = membershipKeyGen(rlnInstance.value)
        var pkBuffer = Buffer(`ptr`: addr(memberKeys.get().idCommitment[0]), len: 32)
        member_is_added = update_next_member(rlnInstance.value, addr pkBuffer)
      # check the member is added
      doAssert(member_is_added)

    # prepare the message
    var messageBytes {.noinit.}: array[32, byte]
    for x in messageBytes.mitems: x = 1
    var messageHex = messageBytes.toHex()
    debug "message", messageHex

    # prepare the epoch
    var  epochBytes : array[32,byte]
    for x in epochBytes.mitems : x = 0
    var epochHex = epochBytes.toHex()
    debug "epoch in bytes", epochHex


    # serialize message and epoch 
    # TODO add a proc for serializing
    var epochMessage = @epochBytes & @messageBytes
    doAssert(epochMessage.len == 64)
    var inputBytes{.noinit.}: array[64, byte] # holds epoch||Message 
    for (i, x) in inputBytes.mpairs: x = epochMessage[i]
    var inputHex = inputBytes.toHex()
    debug "serialized epoch and message ", inputHex
    # put the serialized epoch||message into a buffer
    var inputBuffer = Buffer(`ptr`: addr(inputBytes[0]), len: 64)

    # generate the proof
    var proof: Buffer
    let proofIsSuccessful = generate_proof(rlnInstance.value, addr inputBuffer, addr authObj, addr proof)
    # check whether the generate_proof call is done successfully
    doAssert(proofIsSuccessful)
    var proofValue = cast[ptr array[416,byte]] (proof.`ptr`)
    let proofHex = proofValue[].toHex
    debug "proof content", proofHex

    # display the proof breakdown
    var 
      zkSNARK = proofHex[0..511]
      proofRoot = proofHex[512..575] 
      proofEpoch = proofHex[576..639]
      shareX = proofHex[640..703]
      shareY = proofHex[704..767]
      nullifier = proofHex[768..831]

    doAssert(zkSNARK.len == 512)
    doAssert(proofRoot.len == 64)
    doAssert(proofEpoch.len == 64)
    doAssert(epochHex == proofEpoch)
    doAssert(shareX.len == 64)
    doAssert(shareY.len == 64)
    doAssert(nullifier.len == 64)

    debug "zkSNARK ", zkSNARK
    debug "root ", proofRoot
    debug "epoch ", proofEpoch
    debug "shareX", shareX
    debug "shareY", shareY
    debug "nullifier", nullifier

    var f = 0.uint32
    let verifyIsSuccessful = verify(rlnInstance.value, addr proof, addr f)
    doAssert(verifyIsSuccessful)
    # f = 0 means the proof is verified
    doAssert(f == 0)

    # create and test a bad proof
    # prepare a bad authentication object with a wrong peer's index
    var badIndex = 8
    var badAuthObj: Auth = Auth(secret_buffer: addr skBuffer, index: uint(badIndex))
    var badProof: Buffer
    let badProofIsSuccessful = generate_proof(rlnInstance.value, addr inputBuffer, addr badAuthObj, addr badProof)
    # check whether the generate_proof call is done successfully
    doAssert(badProofIsSuccessful)

    var badF = 0.uint32
    let badVerifyIsSuccessful = verify(rlnInstance.value, addr badProof, addr badF)
    doAssert(badVerifyIsSuccessful)
    # badF=1 means the proof is not verified
    # verification of the bad proof should fail
    doAssert(badF == 1)