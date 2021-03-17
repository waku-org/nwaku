import
  chronos, chronicles, options, stint, unittest,
  web3,
  stew/byteutils, stew/shims/net as stewNet,
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

    # generate the membership keys
    let membershipKeyPair = membershipKeyGen()
    
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

proc generateKeyPairBuffer(ctx: ptr RLN[Bn256]): ptr Buffer = 
  var 
    keysBuffer : Buffer
    keysBufferPtr = unsafeAddr(keysBuffer)
    done = key_gen(ctx, keysBufferPtr) 
  
  return keysBufferPtr

proc getSKPK2(keyPairBuffer: ptr Buffer): (ptr Buffer, ptr Buffer) =
  var 
    generatedKeys = cast[array[64, byte]](keyPairBuffer.`ptr`[])
    secret = cast[array[32, byte]](generatedKeys[0..31])
    public = cast[array[32, byte]](generatedKeys[32..63])
  let skBuffer = Buffer(`ptr`: unsafeAddr(secret[0]), len: 32)
  let skBufferPtr = unsafeAddr skBuffer
  let pkBuffer = Buffer(`ptr`: unsafeAddr(public[0]), len: 32)
  let pkBufferPtr = unsafeAddr pkBuffer
  # echo "keys", generatedKeys
  # echo "secret", secret
  # echo "secret length", secret.len
  # echo "public", public
  # echo "secret length", public.len
  
  return (skBufferPtr, pkBufferPtr)

proc getSKPK(keyPairBuffer: ptr Buffer): (ptr Buffer, ptr Buffer) =
  var 
    generatedKeys = cast[array[64, byte]](keyPairBuffer.`ptr`[])
    secret: array[32, byte] 
    public: array[32, byte]
  for (i,x) in secret.mpairs: x = generatedKeys[i]
  for (i,x) in public.mpairs: x = generatedKeys[i+32]

  let skBuffer = Buffer(`ptr`: unsafeAddr(secret[0]), len: 32)
  let skBufferPtr = unsafeAddr skBuffer
  let pkBuffer = Buffer(`ptr`: unsafeAddr(public[0]), len: 32)
  let pkBufferPtr = unsafeAddr pkBuffer

  return (skBufferPtr, pkBufferPtr)


proc genRandPK(): ptr Buffer =
  var 
    pkBytes : array[32, byte] 
  for x in pkBytes.mitems: x = 2
  let pkBuffer = Buffer(`ptr`: unsafeAddr(pkBytes[0]), len: 32)
  let pkBufferPtr = unsafeAddr pkBuffer
  return pkBufferPtr

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
    var key = membershipKeyGen()
    var empty : array[32,byte]
    check:
      key.isSome
      key.get().secretKey.len == 32
      key.get().publicKey.len == 32
      key.get().secretKey != empty
      key.get().publicKey != empty
    
    debug "the generated membership key pair: ", key 
  
  test "update_next_member Nim Wrapper":
    var ctxInstance = createRLNInstance(32) 
    doAssert(ctxInstance.isSome())
    var ctx = ctxInstance.get()
    
    var keypair = membershipKeyGen(some(ctx))
    doAssert(keypair.isSome())
    let keysBuffer = Buffer(`ptr`: unsafeAddr(keypair.get().publicKey[0]), len: 32)
    let keysBufferPtr = unsafeAddr keysBuffer

    var member_is_added = update_next_member(ctx, keysBufferPtr)
    check:
      member_is_added == true
  
  test "generate_proof Nim Wrapper":
    var ctxInstance = createRLNInstance(32) 
    doAssert(ctxInstance.isSome())
    # ptr RLN[Bn256]
    var ctx = ctxInstance.get() 
    
    # prepare user's secret and public keys 
    let 
      keypairBufferPtr = generateKeyPairBuffer(ctx)
      (skBufferPtr,pkBufferPtr) = keypairBufferPtr.getSKPK()

    # user's index in the tree
    var index = 6

  #   # prepare the secret information of the proof i.e., the sk and the user index in the tree
  #   var auth: Auth = Auth(secret_buffer: skBufferPtr, index: uint(index))
  #   var auth_Ptr = unsafeAddr(auth)

  #   debug "auth", auth

  #   # add some random members to the tree
  #   # TODO add a test for a wrong index, it should fail
  #   for i in 0..10:
  #     echo i
  #     if (i == index):
  #       var member_is_added = update_next_member(ctx, pkBufferPtr)
  #       doAssert(member_is_added)
  #     else:
  #       let randPkPtr = genRandPK()
  #       var member_is_added = update_next_member(ctx, randPkPtr)
  #       doAssert(member_is_added)


  #   # prepare the epoch
  #   let
  #     epoch: uint = 1
  #     epochBytes = cast[array[32,byte]](epoch)
  #   debug "epochBytes", epochBytes
  #   # let decodeEpoch = cast[uint](epochBytes)
  #   # debug "epoch", decodeEpoch
  #   # doAssert(decodeEpoch == epoch)

  #   # prepare the message
  #   var messageBytes {.noinit.}: array[32, byte]
  #   for x in messageBytes.mitems: x = 1
  #   debug "messageBytes", messageBytes

  #   # serialize message and epoch 
  #   var 
  #     epochBytesSeq = @epochBytes
  #     messageBytesSeq = @messageBytes
  #     epochMessage = epochBytesSeq & messageBytesSeq
  #   debug "@epochBytes", epochBytesSeq
  #   debug "@messageBytes", messageBytesSeq
  #   debug "epoch||Message", epochMessage
  #   var inputBytes{.noinit.}: array[64, byte] #the serialized epoch||Message 
  #   for (i, x) in inputBytes.mpairs: x = epochMessage[i]
  #   var
  #     input_buffer = Buffer(`ptr`: unsafeAddr(inputBytes[0]), len: 64)
  #     input_buffer_ptr = unsafeAddr(input_buffer)

  #   debug "inputBytes", inputBytes
  #   debug "input_buffer", input_buffer


  #   # generate the proof
  #   var proof: Buffer
  #   var proofPtr = unsafeAddr(proof)
  #   let proof_res = generate_proof(ctx, input_buffer_ptr, authPtr, proofPtr)

  #   check:
  #     proof_res == true
