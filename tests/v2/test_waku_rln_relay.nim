
{.used.}

import
  std/options, sequtils,
  testutils/unittests, chronos, chronicles, stint, web3,
  stew/byteutils, stew/shims/net as stewNet,
  libp2p/crypto/crypto,
  ../../waku/v2/protocol/waku_rln_relay/[rln, waku_rln_relay_utils, waku_rln_relay_types],
  ../../waku/v2/node/wakunode2,
  ../test_helpers,
  ./test_utils

const RLNRELAY_PUBSUB_TOPIC = "waku/2/rlnrelay/proto"

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
    var rlnInstance = createRLNInstance()
    check: rlnInstance.isOk == true

    # generate the membership keys
    let membershipKeyPair = membershipKeyGen(rlnInstance.value)
    
    check: membershipKeyPair.isSome

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
  asyncTest "mounting waku rln-relay":
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
    var rlnInstance = createRLNInstance()
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
    node.mountRelay(@[RLNRELAY_PUBSUB_TOPIC])
    await node.mountRlnRelay(ethClientAddrOpt = some(EthClient), ethAccAddrOpt =  some(ethAccountAddress), memContractAddOpt =  some(membershipContractAddress), groupOpt = some(group), memKeyPairOpt = some(keypair.get()),  memIndexOpt = some(index), pubsubTopic = RLNRELAY_PUBSUB_TOPIC)
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().toHex
    debug "calculated root ", calculatedRoot

    check expectedRoot == calculatedRoot

    await node.stop()

  asyncTest "mount waku-rln-relay in the off-chain mode":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
    await node.start()

    # preparing inputs to mount rln-relay

    # create a group of 100 membership keys
    let
      (groupKeys, root) = createMembershipList(100)
    check groupKeys.len == 100
    let 
      # convert the keys to MembershipKeyPair structs
      groupKeyPairs = groupKeys.toMembershipKeyPairs()
      # extract the id commitments
      groupIDCommitments = groupKeyPairs.mapIt(it.idCommitment)
    debug "groupKeyPairs", groupKeyPairs
    debug "groupIDCommitments", groupIDCommitments
   
    # index indicates the position of a membership key pair in the static list of group keys i.e., groupKeyPairs 
    # the corresponding key pair will be used to mount rlnRelay on the current node
    # index also represents the index of the leaf in the Merkle tree that contains node's commitment key 
    let index = MembershipIndex(5)

    # -------- mount rln-relay in the off-chain mode
    node.mountRelay(@[RLNRELAY_PUBSUB_TOPIC])
    await node.mountRlnRelay(groupOpt = some(groupIDCommitments), memKeyPairOpt = some(groupKeyPairs[index]),  memIndexOpt = some(index), onchainMode = false, pubsubTopic = RLNRELAY_PUBSUB_TOPIC)
    
    # get the root of Merkle tree which is constructed inside the mountRlnRelay proc
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().toHex
    debug "calculated root by mountRlnRelay", calculatedRoot

    # this part checks whether the Merkle tree is constructed correctly inside the mountRlnRelay proc
    # this check is done by comparing the tree root resulted from mountRlnRelay i.e., calculatedRoot 
    # against the root which is the expected root
    check calculatedRoot == root

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
    var rlnInstance = createRLNInstance()
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
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true

    # read the Merkle Tree root
    var 
      root1 {.noinit.} : Buffer = Buffer()
      rootPtr1 = addr(root1)
      get_root_successful1 = get_root(rlnInstance.value, rootPtr1)
    check:
      get_root_successful1
      root1.len == 32

    # read the Merkle Tree root
    var 
      root2 {.noinit.} : Buffer = Buffer()
      rootPtr2 = addr(root2)
      get_root_successful2 = get_root(rlnInstance.value, rootPtr2)
    check: 
      get_root_successful2
      root2.len == 32

    var rootValue1 = cast[ptr array[32,byte]] (root1.`ptr`)
    let rootHex1 = rootValue1[].toHex

    var rootValue2 = cast[ptr array[32,byte]] (root2.`ptr`)
    let rootHex2 = rootValue2[].toHex

    # the two roots must be identical
    check rootHex1 == rootHex2
  test "getMerkleRoot utils":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true

    # read the Merkle Tree root
    var root1 = getMerkleRoot(rlnInstance.value())
    check root1.isOk
    let rootHex1 = root1.value().toHex

    # read the Merkle Tree root
    var root2 = getMerkleRoot(rlnInstance.value())
    check root2.isOk
    let rootHex2 = root2.value().toHex

    # the two roots must be identical
    check rootHex1 == rootHex2

  test "update_next_member Nim Wrapper":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true

    # generate a key pair
    var keypair = membershipKeyGen(rlnInstance.value)
    check keypair.isSome()
    var pkBuffer = toBuffer(keypair.get().idCommitment)
    let pkBufferPtr = addr pkBuffer

    # add the member to the tree
    var member_is_added = update_next_member(rlnInstance.value, pkBufferPtr)
    check:
      member_is_added == true
    
  test "delete_member Nim wrapper":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true

    # delete the first member 
    var deleted_member_index = MembershipIndex(0)
    let deletion_success = delete_member(rlnInstance.value, deleted_member_index)
    check deletion_success

  test "insertMember rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value
    # generate a key pair
    var keypair = rln.membershipKeyGen()
    check keypair.isSome()
    check:
      rln.insertMember(keypair.get().idCommitment)  
    
  test "removeMember rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value
    check: 
      rln.removeMember(MembershipIndex(0))

  test "Merkle tree consistency check between deletion and insertion":
    # create an RLN instance
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true

    # read the Merkle Tree root
    var 
      root1 {.noinit.} : Buffer = Buffer()
      rootPtr1 = addr(root1)
      get_root_successful1 = get_root(rlnInstance.value, rootPtr1)
    check:
      get_root_successful1
      root1.len == 32
    
    # generate a key pair
    var keypair = membershipKeyGen(rlnInstance.value)
    check: keypair.isSome()
    var pkBuffer = toBuffer(keypair.get().idCommitment)
    let pkBufferPtr = addr pkBuffer

    # add the member to the tree
    var member_is_added = update_next_member(rlnInstance.value, pkBufferPtr)
    check member_is_added

    # read the Merkle Tree root after insertion
    var 
      root2 {.noinit.} : Buffer = Buffer()
      rootPtr2 = addr(root2)
      get_root_successful2 = get_root(rlnInstance.value, rootPtr2)
    check:
      get_root_successful2
      root2.len == 32

    # delete the first member 
    var deleted_member_index = MembershipIndex(0)
    let deletion_success = delete_member(rlnInstance.value, deleted_member_index)
    check deletion_success

    # read the Merkle Tree root after the deletion
    var 
      root3 {.noinit.} : Buffer = Buffer()
      rootPtr3 = addr(root3)
      get_root_successful3 = get_root(rlnInstance.value, rootPtr3)
    check:
      get_root_successful3
      root3.len == 32

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
    check: not(rootHex1 == rootHex2)

    ## The initial root of the tree (empty tree) must be identical to 
    ## the root of the tree after one insertion followed by a deletion
    check rootHex1 == rootHex3
  test "Merkle tree consistency check between deletion and insertion using rln utils":
    # create an RLN instance
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value()

    # read the Merkle Tree root
    var root1 = rln.getMerkleRoot()
    check root1.isOk
    let rootHex1 = root1.value().toHex()
    
    # generate a key pair
    var keypair = rln.membershipKeyGen()
    check keypair.isSome()
    let member_inserted = rln.insertMember(keypair.get().idCommitment) 
    check member_inserted

    # read the Merkle Tree root after insertion
    var root2 = rln.getMerkleRoot()
    check root2.isOk
    let rootHex2 = root2.value().toHex()

  
    # delete the first member 
    var deleted_member_index = MembershipIndex(0)
    let deletion_success = rln.removeMember(deleted_member_index)
    check deletion_success

    # read the Merkle Tree root after the deletion
    var root3 = rln.getMerkleRoot()
    check root3.isOk
    let rootHex3 = root3.value().toHex()


    debug "The initial root", rootHex1
    debug "The root after insertion", rootHex2
    debug "The root after deletion", rootHex3

    # the root must change after the insertion
    check not(rootHex1 == rootHex2)

    ## The initial root of the tree (empty tree) must be identical to 
    ## the root of the tree after one insertion followed by a deletion
    check rootHex1 == rootHex3

  test "hash Nim Wrappers":
    # create an RLN instance
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true
    
    # prepare the input
    var 
      msg = "Hello".toBytes()
      hashInput = appendLength(msg)
      hashInputBuffer = toBuffer(hashInput) 

    # prepare other inputs to the hash function
    var outputBuffer: Buffer
    
    let hashSuccess = hash(rlnInstance.value, addr hashInputBuffer, addr outputBuffer)
    check hashSuccess
    let outputArr = cast[ptr array[32,byte]](outputBuffer.`ptr`)[]
    check:
      "efb8ac39dc22eaf377fe85b405b99ba78dbc2f3f32494add4501741df946bd1d" == outputArr.toHex()

    var 
      hashOutput = cast[ptr array[32,byte]] (outputBuffer.`ptr`)[]
      hashOutputHex = hashOutput.toHex()

    debug "hash output", hashOutputHex

  test "hash utils":
    # create an RLN instance
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true
    let rln = rlnInstance.value
    
    # prepare the input
    let msg = "Hello".toBytes()

    let hash = rln.hash(msg)
    check:
      "efb8ac39dc22eaf377fe85b405b99ba78dbc2f3f32494add4501741df946bd1d" == hash.toHex()
  
  test "create a list of membership keys and construct a Merkle tree based on the list":
    let 
      groupSize = 100
      (list, root) = createMembershipList(groupSize) 

    debug "created membership key list", list
    debug "the Merkle tree root", root
    
    check:
      list.len == groupSize  # check the number of keys
      root.len == HASH_HEX_SIZE # check the size of the calculated tree root
  
  test "check correctness of toMembershipKeyPairs and calcMerkleRoot":
    let groupKeys = STATIC_GROUP_KEYS

    # create a set of MembershipKeyPair objects from groupKeys
    let groupKeyPairs = groupKeys.toMembershipKeyPairs()
    # extract the id commitments
    let groupIDCommitments = groupKeyPairs.mapIt(it.idCommitment)
    # calculate the Merkle tree root out of the extracted id commitments
    let root = calcMerkleRoot(groupIDCommitments)

    debug "groupKeyPairs", groupKeyPairs
    debug "groupIDCommitments", groupIDCommitments
    debug "root", root

    check: 
      # check that the correct number of key pairs is created
      groupKeyPairs.len == StaticGroupSize
      # compare the calculated root against the correct root
      root == STATIC_GROUP_MERKLE_ROOT
  
  test "RateLimitProof Protobuf encode/init test":
    var 
      proof: ZKSNARK
      merkleRoot: MerkleNode
      epoch: Epoch
      shareX: MerkleNode
      shareY: MerkleNode
      nullifier: Nullifier
    # populate fields with dummy values
    for x in proof.mitems : x = 1
    for x in merkleRoot.mitems : x = 2
    for x in epoch.mitems : x = 3
    for x in shareX.mitems : x = 4
    for x in shareY.mitems : x = 5
    for x in nullifier.mitems : x = 6
    
    let 
      rateLimitProof = RateLimitProof(proof: proof,
                          merkleRoot: merkleRoot,
                          epoch: epoch,
                          shareX: shareX,
                          shareY: shareY,
                          nullifier: nullifier)
      protobuf = rateLimitProof.encode()
      decodednsp = RateLimitProof.init(protobuf.buffer)

    check:
      decodednsp.isErr == false
      decodednsp.value == rateLimitProof

  test "test proofVerify and proofGen for a valid proof":
    var rlnInstance = createRLNInstance()
    check rlnInstance.isOk
    var rln = rlnInstance.value

    let 
      # create a membership key pair
      memKeys = membershipKeyGen(rln).get()
      # peer's index in the Merkle Tree
      index = 5

    # Create a Merkle tree with random members 
    for i in 0..10:
      var member_is_added: bool = false
      if (i == index):
        # insert the current peer's pk
        member_is_added = rln.insertMember(memKeys.idCommitment)
      else:
        # create a new key pair
        let memberKeys = rln.membershipKeyGen()
        member_is_added = rln.insertMember(memberKeys.get().idCommitment)
      # check the member is added
      check member_is_added

    # prepare the message 
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    var  epoch : Epoch
    debug "epoch", epochHex=epoch.toHex()

    # generate proof
    let proofRes = rln.proofGen(data = messageBytes, 
                                memKeys = memKeys,
                                memIndex = MembershipIndex(index),
                                epoch = epoch)
    check proofRes.isOk()
    let proof = proofRes.value
    
    # verify the proof
    let verified = rln.proofVerify(data = messageBytes,
                                    proof = proof)
    check verified == true

  test "test proofVerify and proofGen for an invalid proof":
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value

    let 
      # create a membership key pair
      memKeys = membershipKeyGen(rln).get()
      # peer's index in the Merkle Tree
      index = 5

    # Create a Merkle tree with random members 
    for i in 0..10:
      var member_is_added: bool = false
      if (i == index):
        # insert the current peer's pk
        member_is_added = rln.insertMember(memKeys.idCommitment)
      else:
        # create a new key pair
        let memberKeys = rln.membershipKeyGen()
        member_is_added = rln.insertMember(memberKeys.get().idCommitment)
      # check the member is added
      check member_is_added

     # prepare the message 
    let messageBytes = "Hello".toBytes()

    # prepare the epoch
    var  epoch : Epoch
    debug "epoch in bytes", epochHex=epoch.toHex()


    let badIndex = 4
    # generate proof
    let proofRes = rln.proofGen(data = messageBytes, 
                                memKeys = memKeys,
                                memIndex = MembershipIndex(badIndex),
                                epoch = epoch)
    check proofRes.isOk()
    let proof = proofRes.value

    # verify the proof (should not be verified)
    let verified = rln.proofVerify(data = messageBytes,
                                 proof = proof)
    check verified == false
