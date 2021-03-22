import
  chronos, chronicles, options, stint, unittest,
  web3,
  stew/byteutils as stewByteUtils, stew/shims/net as stewNet,
  libp2p/crypto/crypto,
  ../../waku/v2/protocol/waku_rln_relay/[rln, waku_rln_relay_utils],
  ../../waku/v2/node/wakunode2,
  ../test_helpers,
  test_utils


  

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
    var 
      ctx = RLN[Bn256]()
      ctxPtr = unsafeAddr(ctx)
      ctxPtrPtr = unsafeAddr(ctxPtr)
    createRLNInstance(32, ctxPtrPtr)

    # generate the membership keys
    let membershipKeyPair = membershipKeyGen(ctxPtrPtr[])
    
    check:
      membershipKeyPair.isSome

    # initialize the WakuRLNRelay 
    var rlnPeer = WakuRLNRelay(membershipKeyPair: membershipKeyPair.get(),
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
      node = WakuNode.init(nodeKey, ValidIpAddress.init("0.0.0.0"),
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

    # start rln-relay
    await node.mountRlnRelay(ethClientAddress = some(EthClient), ethAccountAddress =  some(ethAccountAddress), membershipContractAddress =  some(membershipContractAddress))


# TODO unit test for genSKPK
proc genSKPK(ctx: ptr RLN[Bn256]): (Buffer, Buffer) =
  var keypair = membershipKeyGen(ctx)
  doAssert(keypair.isSome())
  let pkBuffer = Buffer(`ptr`: unsafeAddr(keypair.get().publicKey[0]), len: 32)

  let skBuffer = Buffer(`ptr`: unsafeAddr(keypair.get().secretKey[0]), len: 32)
  return(skBuffer,pkBuffer)

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
      parametersBuffer = Buffer(`ptr`: unsafeAddr(pbytes[0]), len: len)
    check:
      # check the parameters.key is not empty
      pbytes.len != 0

    # ctx holds the information that is going to be used for  the key generation
    var 
      obj = RLN[Bn256]()
      objPtr = unsafeAddr(obj)
      objptrptr = unsafeAddr(objPtr)
      ctx = objptrptr
    let res = new_circuit_from_params(merkleDepth, unsafeAddr parametersBuffer, ctx)
    check:
      # check whether the circuit parameters are generated successfully
      res == true

    # keysBufferPtr will hold the generated key pairs i.e., secret and public keys 
    var 
      keysBuffer : Buffer
      keysBufferPtr = unsafeAddr(keysBuffer)
      done = key_gen(ctx[], keysBufferPtr) 
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
    var 
      ctx = RLN[Bn256]()
      ctxPtr = unsafeAddr(ctx)
      ctxPtrPtr = unsafeAddr(ctxPtr)
    createRLNInstance(32, ctxPtrPtr)

    var key = membershipKeyGen(ctxPtrPtr[])
    var empty : array[32,byte]
    check:
      key.isSome
      key.get().secretKey.len == 32
      key.get().publicKey.len == 32
      key.get().secretKey != empty
      key.get().publicKey != empty
    
    debug "the generated membership key pair: ", key 
  
  test "get_root Nim binding":
    # create an RLN instance which includes an empty Merkle tree inside its struct
    var 
      ctx = RLN[Bn256]()
      ctxPtr = unsafeAddr(ctx)
      ctxPtrPtr = unsafeAddr(ctxPtr)
    createRLNInstance(32, ctxPtrPtr)

    # read the Merkle Tree root
    var 
      root1 {.noinit.} : Buffer = Buffer()
      rootPtr1 = unsafeAddr(root1)
      get_root_successful1 = get_root(ctxPtrPtr[], rootPtr1)
    doAssert(get_root_successful1)
    doAssert(root1.len == 32)

    # read the Merkle Tree root
    var 
      root2 {.noinit.} : Buffer = Buffer()
      rootPtr2 = unsafeAddr(root2)
      get_root_successful2 = get_root(ctxPtrPtr[], rootPtr2)
    doAssert(get_root_successful2)
    doAssert(root2.len == 32)

    var rootValue1 = cast[ptr array[32,byte]] (root1.`ptr`)
    let rootHex1 = rootValue1[].toHex

    var rootValue2 = cast[ptr array[32,byte]] (root2.`ptr`)
    let rootHex2 = rootValue2[].toHex

    # the two roots must be identical
    doAssert(rootHex1 == rootHex2)

  test "update_next_member Nim Wrapper":
    # create an RLN instance which includes an empty Merkle tree inside its struct
    var 
      ctx = RLN[Bn256]()
      ctxPtr = unsafeAddr(ctx)
      ctxPtrPtr = unsafeAddr(ctxPtr)
    createRLNInstance(32, ctxPtrPtr)

    # generate a key pair
    var keypair = membershipKeyGen(ctxPtrPtr[])
    doAssert(keypair.isSome())
    let pkBuffer = Buffer(`ptr`: unsafeAddr(keypair.get().publicKey[0]), len: 32)
    let pkBufferPtr = unsafeAddr pkBuffer

    # add the member to the tree
    var member_is_added = update_next_member(ctxPtrPtr[], pkBufferPtr)
    check:
      member_is_added == true
      
  test "delete_member Nim wrapper":
    # create an RLN instance which includes an empty Merkle tree inside its struct
    var 
      ctx = RLN[Bn256]()
      ctxPtr = unsafeAddr(ctx)
      ctxPtrPtr = unsafeAddr(ctxPtr)
    createRLNInstance(32, ctxPtrPtr)

    # delete the first member 
    var deleted_member_index = uint(0)
    let deletion_success = delete_member(ctxPtrPtr[], deleted_member_index)
    doAssert(deletion_success)
  
  test "Merkle tree consistency check between deletion and insertion":
    # create an RLN instance
    var 
      ctx = RLN[Bn256]()
      ctxPtr = unsafeAddr(ctx)
      ctxPtrPtr = unsafeAddr(ctxPtr)
    createRLNInstance(32, ctxPtrPtr)

    # read the Merkle Tree root
    var 
      root1 {.noinit.} : Buffer = Buffer()
      rootPtr1 = unsafeAddr(root1)
      get_root_successful1 = get_root(ctxPtrPtr[], rootPtr1)
    doAssert(get_root_successful1)
    doAssert(root1.len == 32)
    
    # generate a key pair
    var keypair = membershipKeyGen(ctxPtrPtr[])
    doAssert(keypair.isSome())
    let pkBuffer = Buffer(`ptr`: unsafeAddr(keypair.get().publicKey[0]), len: 32)
    let pkBufferPtr = unsafeAddr pkBuffer

    # add the member to the tree
    var member_is_added = update_next_member(ctxPtrPtr[], pkBufferPtr)
    doAssert(member_is_added)

    # read the Merkle Tree root after insertion
    var 
      root2 {.noinit.} : Buffer = Buffer()
      rootPtr2 = unsafeAddr(root2)
      get_root_successful2 = get_root(ctxPtrPtr[], rootPtr2)
    doAssert(get_root_successful2)
    doAssert(root2.len == 32)

    # delete the first member 
    var deleted_member_index = uint(0)
    let deletion_success = delete_member(ctxPtrPtr[], deleted_member_index)
    doAssert(deletion_success)

    # read the Merkle Tree root after the deletion
    var 
      root3 {.noinit.} : Buffer = Buffer()
      rootPtr3 = unsafeAddr(root3)
      get_root_successful3 = get_root(ctxPtrPtr[], rootPtr3)
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


    doAssert(rootHex1 == rootHex3)
    doAssert(not(rootHex1 == rootHex2))
  
  # test "generate_proof and verify Nim Wrappers":
  #   # create an RLN instance
  #   var 
  #     ctx = RLN[Bn256]()
  #     ctxPtr = unsafeAddr(ctx)
  #     ctxPtrPtr = unsafeAddr(ctxPtr)
  #   createRLNInstance(32, ctxPtrPtr)


  #   var root {.noinit.} : Buffer = Buffer()
  #   var rootPtr = unsafeAddr(root)
  #   var get_root_successful = get_root(ctxPtrPtr[],rootPtr)
  #   doAssert(get_root_successful)
  #   root = rootPtr[]
  #   var rootSize = root.len
  #   # debug "rootSize", rootSize
  #   var rootValue = cast[ptr array[32,byte]] (rootPtr.`ptr`)
  #   echo "initial root ", rootValue[].toHex

  #   var root2 {.noinit.} : Buffer = Buffer()
  #   var rootPtr2 = unsafeAddr(root2)
  #   var get_root_successful2 = get_root(ctxPtrPtr[],rootPtr2)
  #   doAssert(get_root_successful2)
  #   root2 = rootPtr2[]
  #   var rootSize2 = root2.len
  #   # debug "rootSize", rootSize
  #   var rootValue2 = cast[ptr array[32,byte]] (rootPtr2.`ptr`)
  #   echo "initial root second call ", rootValue2[].toHex


  #   var root3 {.noinit.} : Buffer = Buffer()
  #   var rootPtr3 = unsafeAddr(root3)
  #   var get_root_successful3 = get_root(ctxPtrPtr[],rootPtr3)
  #   doAssert(get_root_successful3)
  #   root3 = rootPtr3[]
  #   var rootSize3 = root3.len
  #   # debug "rootSize", rootSize
  #   var rootValue3 = cast[ptr array[32,byte]] (rootPtr3.`ptr`)
  #   echo "initial root third call ", rootValue3[].toHex

   


  #   # prepare user's secret and public keys 
  #   var (skBuffer,pkBuffer) = genSKPK(ctxPtrPtr[])
  #   let 
  #     skBufferPtr = unsafeAddr skBuffer
  #     pkBufferPtr = unsafeAddr pkBuffer

  #   # user's index in the tree
  #   var index = 5

  #   # prepare the secret information of the proof i.e., the sk and the user index in the tree
  #   var auth: Auth = Auth(secret_buffer: skBufferPtr, index: uint(index))
  #   var authPtr = unsafeAddr(auth)

  #   debug "auth", auth

  #   rootPtr = unsafeAddr(root)
  #   get_root_successful = get_root(ctxPtrPtr[],rootPtr)
  #   doAssert(get_root_successful)
  #   rootSize = root.len
  #   # debug "rootSize", rootSize
  #   rootValue = cast[ptr array[32,byte]] (root.`ptr`)
  #   echo "initial root after key gen", rootValue[].toHex


  #   # add some random members to the tree
  #   for i in 0..10:
  #     echo i
  #     var member_is_added: bool = false
  #     if (i == index):
  #       member_is_added = update_next_member(ctxPtrPtr[], pkBufferPtr)
  #       var root : Buffer
  #       var rootPtr = unsafeAddr(root)
  #       var get_root_successful = get_root(ctxPtrPtr[],rootPtr)
  #       doAssert(get_root_successful)
  #       var rootSize = root.len
  #       # debug "rootSize", rootSize
  #       var rootValue = cast[ptr array[32,byte]] (root.`ptr`)
  #       echo "root value ", i, " ", rootValue[].toHex
  #     else:
  #       var (sk,pk) = genSKPK(ctxPtrPtr[])
  #       # var pk = genRandPK()
  #       let pkPtr = unsafeAddr pk
  #       member_is_added = update_next_member(ctxPtrPtr[], pkPtr)
  #       var root : Buffer
  #       var rootPtr = unsafeAddr(root)
  #       var get_root_successful = get_root(ctxPtrPtr[],rootPtr)
  #       doAssert(get_root_successful)
  #       var rootSize = root.len
  #       # debug "rootSize", rootSize
  #       var rootValue = cast[ptr array[32,byte]] (root.`ptr`)
  #       echo "root value ", i, " " , rootValue[].toHex
  #     doAssert(member_is_added)

  #   var deleted_member_index = uint(10)
  #   let deletion_success = delete_member(ctxPtrPtr[], deleted_member_index)
  #   doAssert(deletion_success)
  #   # var root : Buffer
  #   rootPtr = unsafeAddr(root)
  #   get_root_successful = get_root(ctxPtrPtr[],rootPtr)
  #   doAssert(get_root_successful)
  #   rootSize = root.len
  #   # debug "rootSize", rootSize
  #   rootValue = cast[ptr array[32,byte]] (root.`ptr`)
  #   echo "root value after 10 is deleted ", rootValue[].toHex

  #   # prepare the message
  #   var messageBytes {.noinit.}: array[32, byte]
  #   for x in messageBytes.mitems: x = 1
  #   debug "messageBytes", messageBytes


  #   # prepare the epoch
  #   # let
  #   #   epoch: uint = 1
  #   var  epochBytes : array[32,byte]
  #   for x in epochBytes.mitems : x = 0
  #   debug "epochBytes", epochBytes
   

  #   # serialize message and epoch 
  #   # TODO add a proc for serializing
  #   var epochMessage = @epochBytes & @messageBytes
  #   echo "epoch in Bytes", epochBytes.toHex()
  #   echo "message in Bytes", messageBytes.toHex()
  #   echo "epoch||Message", stewByteUtils.toHex(epochMessage)
  #   doAssert(epochMessage.len == 64)
  #   var inputBytes{.noinit.}: array[64, byte] #the serialized epoch||Message 
  #   for (i, x) in inputBytes.mpairs: x = epochMessage[i]
  #   var
  #     input_buffer = Buffer(`ptr`: unsafeAddr(inputBytes[0]), len: 64)
  #     input_buffer_ptr = unsafeAddr(input_buffer)

  #   echo "inputBytes", inputBytes.toHex()
  #   # debug "input_buffer", input_buffer

  #   # test a simple hash
  #   # var
  #   #   sample_hash_input_bytes : array[32, byte]
  #   # for x in sample_hash_input_bytes.mitems: x= 1

  #   # echo "sample_hash_input_buffer", sample_hash_input_bytes.toHex()
  #   # echo sample_hash_input_bytes

  #   # var 
  #   #   output_buffer: Buffer
  #   #   output_buffer_ptr = unsafeAddr output_buffer
  #   #   data_length = 32.uint
  #   #   sample_hash_input_buffer = Buffer(`ptr`: unsafeAddr(messageBytes[0]), len: 32 ) 
      
  #   # # var (sample_hash_input_buffer,_) = genSKPK(ctxPtrPtr[])
  #   # let hash_success = hash(ctxPtrPtr[], unsafeAddr(sample_hash_input_buffer), data_length, output_buffer_ptr)
  #   # # doAssert(hash_success)
  #   # var hashoutput = cast[ptr array[32,byte]] (output_buffer_ptr.`ptr`)
  #   # echo "output_buffer ", hashoutput[].toHex()



  #   # generate the proof
  #   var proof: Buffer
  #   var proofPtr = unsafeAddr(proof)
  #   let proof_res = generate_proof(ctxPtrPtr[], input_buffer_ptr, authPtr, proofPtr)
  #   var proofValue = cast[ptr array[416,byte]] (proof.`ptr`)
  #   echo "proof content", proofValue[].toHex
  #   let proofHex = proofValue[].toHex
  
  #   check:
  #     proof_res == true
  #     proof.len ==  416
  #     proofHex.len == 832
  
  #   var 
  #   #   proofArray = cast[ptr array[416, byte]] (proof.`ptr`)[]
  #     zkSNARK = proofHex[0..511]
  #     proofRoot = proofHex[512..575] #stewByteUtils.toHex(proofArray[256..287])
  #     proofEpoch = proofHex[576..639]#stewByteUtils.toHex(proofArray[288..319])
  #     shareX = proofHex[640..703]#stewByteUtils.toHex(proofArray[320..352])
  #     shareY = proofHex[704..767]#stewByteUtils.toHex(proofArray[353..383])
  #     nullifier = proofHex[768..831]#stewByteUtils.toHex(proofArray[384..415])
  #   debug "zkSNARK ", zkSNARK
  #   echo(zkSNARK.len == 512)
  #   debug "root ", proofRoot
  #   echo(proofRoot.len == 64)
  #   debug "epoch ", proofEpoch
  #   echo(proofEpoch.len == 64)
  #   debug "shareX", shareX
  #   echo(shareX.len == 64)
  #   debug "shareY", shareY
  #   echo(shareY.len == 64)
  #   debug "nullifier", nullifier
  #   echo(nullifier.len == 64)
    

  #   # TODO add a test for a wrong index, it should fail

  #   var f = 0.uint32
  #   var fPtr = unsafeAddr(f)
  #   let success = verify(ctxPtrPtr[], unsafeAddr proof, fPtr)
  #   doAssert(success)
  #   # TODO the value of f must be zero, but it is not, have to investigate more
  #   # doAssert(f==0)
  #   # f = fPtr[] 
  #   debug "f", f 


    

 
