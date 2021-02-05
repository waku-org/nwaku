import
  chronos, nimcrypto, options, json, stint,
  test_utils,
  web3

# the address of Ethereum client (ganache-cli for now)
const ethClient = "ws://localhost:8540/"

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


proc membershipTest() {.async.} =
  # connect to the eth client
  let web3 = await newWeb3(ethClient)
  echo "web3 connected"

  # fetch the list of registered accounts
  let accounts = await web3.provider.eth_accounts()
  web3.defaultAccount = accounts[1]
  echo "contract deployer account address ", web3.defaultAccount 

  var balance = await web3.provider.eth_getBalance(web3.defaultAccount , "latest")
  echo "Initial account balance: ", balance

  # deploy the poseidon hash first
  let 
    hasherReceipt = await web3.deployContract(poseidonHasherCode)
    hasherAddress = hasherReceipt.contractAddress.get
  echo "hasher address: ", hasherAddress
  
  # inputs of membership contract constructor
  let
    membershipFee = 5.u256
    depth = 5.u256
  
  # encode membership contract inputs to 32 bytes zero-padded
  let 
    membershipFeeEncoded = encode(membershipFee).data 
    depthEncoded = encode(depth).data 
    hasherAddressEncoded = encode(hasherAddress).data
    # this is the contract constructor input
    contractInput = membershipFeeEncoded & depthEncoded & hasherAddressEncoded


  echo "encoded membership fee: ", membershipFeeEncoded
  echo "encoded depth: ", depthEncoded
  echo "encoded hasher address: ", hasherAddressEncoded
  echo "encoded contract input:" , contractInput

  # deploy membership contract with its constructor inputs
  let receipt = await web3.deployContract(membershipContractCode, contractInput = contractInput)
  var contractAddress = receipt.contractAddress.get
  echo "Address of the deployed membership contract: ", contractAddress

  # balance = await web3.provider.eth_getBalance(web3.defaultAccount , "latest")
  # echo "Account balance after the contract deployment: ", balance

  # prepare a contract sender to interact with it
  echo "registering a user..."
  var sender = web3.contractSender(MembershipContract, contractAddress) # creates a Sender object with a web3 field and contract address of type Address

  # send takes three parameters, c: ContractCallBase, value = 0.u256, gas = 3000000'u64 gasPrice = 0 
  # should use send proc for the contract functions that update the state of the contract
  echo "The hash of registration tx: ", await sender.register(20.u256).send(value = membershipFee) # value is the membership fee

  # var members: array[2, uint256] = [20.u256, 21.u256]
  # echo "This is the batch registration result ", await sender.registerBatch(members).send(value = (members.len * membershipFee)) # value is the membership fee

  # balance = await web3.provider.eth_getBalance(web3.defaultAccount , "latest")
  # echo "Balance after registration: ", balance

  await web3.close()
  echo "closed"


waitFor membershipTest()
echo " rln-relay test ended"
