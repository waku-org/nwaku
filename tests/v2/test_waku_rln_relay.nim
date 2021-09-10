
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
    depthEncoded = encode(MerkleTreeDepth.u256).data 
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

proc createMembershipList(n: int): (seq[string], string) = 
  ##  createMembershipList produces an alternating sequence of identity keys and their corresponding id commitment keys in the hexadecimal format
  ## this proc also returns the root of a Merkle tree constructed out of the identity commitment keys of the generated list
  ## the output of this proc is used  to initialize a static group list
  
  # initialize a Merkle tree
  var rlnInstance = createRLNInstance()
  check: rlnInstance.isOk == true
  var rln = rlnInstance.value

  var output = newSeq[string]()
  for i in 0..n-1:

    # generate a key pair
    var keypair = rln.membershipKeyGen()
    doAssert(keypair.isSome())
    
    output.add(keypair.get().idKey.toHex)
    output.add(keypair.get().idCommitment.toHex)

    # insert the key to the Merkle tree
    check: rln.insertMember(keypair.get().idCommitment)  
    

  let root = rln.getMerkleRoot().value.toHex
  return (output, root)


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
    await node.mountRlnRelay(ethClientAddrOpt = some(EthClient), ethAccAddrOpt =  some(ethAccountAddress), memContractAddOpt =  some(membershipContractAddress), groupOpt = some(group), memKeyPairOpt = some(keypair.get()),  memIndexOpt = some(index))
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().toHex
    debug "calculated root ", calculatedRoot

    check expectedRoot == calculatedRoot

    await node.stop()

  asyncTest "mount waku rln-relay off-chain":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
    await node.start()

    var rlnInstance = createRLNInstance()
    check rlnInstance.isOk == true
    var rln = rlnInstance.value

    # current peer index in the Merkle tree
    let index = uint(5)

    # Create a group of 100 members 
    var groupKeys: seq[string] = @["045a90832558f7b56f3f38f56f70bccba392d84f3f1b64ccba6ba21daaf57a1f", "200be495af932e6f83e384393854fb60ec02245f2d630cbb9c701fc9d25f112e", "2e8718c8db83471a19ade90fa1782a593e89f0e6e1555dfcae02d768c155910d", "54e7f26866aae4af2bf3ba81c9d76516c7c2e26a3aa130ae660f05ea3528691c", "545e00fa9a083c962875831b956c9d0d25d27b10b0b02da7feb7f6f3ad474205", "2c57d1be4785d7bb8341635784e48e6f656ee9574f593298302bb15c5583d22a", "d24e4ff2c21ec63c9148887b2a6bd0c2c5daae4bbe889480778f870afea7a02a", "4c338455697992fa98f45cfeda63d6fc7c384e0aebc6603f646f2ed9ec0df204", "9c2d78394523e90ebdfd407a3fe5c31b3bb30d3061358c9fcda6480e1633cd1c", "bee9f122f9fc1887e134f9fe3a55e60cda416263ce1cdd7802fa96b7b0f52619", "0298173e7f2996bd69b4992ac58927fba845b32a919065230bb4c6b377245c05", "7418e583da831e51fa78a90e033f0fcb676adf82af5d03669a002f61cf3ef22e", "1db9bf1a1fdf04d9c8452d5f6c86214f2dc1cdcc56bb3b5f62bcb50282651c21", "27e0c4c13f6e1deea4f7a574269b5f9567645985a21f15b266bc052a856b581f", "714c1f0f5fc782881d26451b2045d68236addc4a782af90b33d8130d1dc2d310", "c3796a90f73a8fd6e9a2e6702075b5b61bd36377cd3f1fba2e55cca60ddcb103", "3721ee9c258a12a96c6db2bd6b85407c20690616c7868cc40cfb78e9f81bba16", "1f569e32ce5f6b31a186bccdeae0dcf0d870462b1ce65ae83972e6f785fbae1d", "ba0746316fdb3e14ed192f62a23f98debfcd3eabe4ae23251e9ecf15032b8312", "2926e40f2f62941e99dda1b647b688f604f224aee3dccb4976cdfccba24aee0b", "c313bc470095373af1efb21f48f7e85935090c02ca016c04adf5650adb28f90a", "eaa5e761efc64949b88ab7eac0fc5331fa4c0c0e755c396983b7873801b5fd0b", "bc69b2eeddeec3a38571de8ebd5782d2230a67eb537aae250bee648eefe89c04", "2f5d17486c310970ace7805773d7654dd9fbc4c254b61fa4612af9b96ba06b17", "00e8fe8d60db239059667286e00804d60b7a93209fbae65f30965a1df26e9717", "599fdd0300101fe0549303e22bb241c2178275448154e09ea0a2ab85ffd26127", "bafb62cf0f58dd3ca10648d64a81318f73dd5d118e9b11e1c5a46a3f7dacb40d", "121c481780bf68cc3bcb1161f30708baf58ee1f06ae57825804cf3ce95869a2a", "6b120e48b20e704efa239b87f0e457ab260bdea86a2f19fac435874685df2d24", "ac00443f4255d5ebcd778b12bd9f0fd957346013a543145549af1cd8f0e8ef0d", "0f444131b66f1728a3eac51eb71b56ffdeef212e5d61a07f3e18b83672677c2d", "66a1fcb111aaa3263f3ce6a44fd0f2722feae4d1d0c6595a69b4d75d595a6b0a", "e0356a4540c0a63f3db9806cf1872fe3d8739276f83f02de0e2165042b841d01", "8e6ce8380c1505b1f9574817d12b5260bb78e9fff4ef56847346caed04401621", "c276a0e8d1e07b033d8df997d7d3f2fdb23054bc63ccaa50aa96580d3f29361b", "a2af0da6570d64e85bbf6facf95a7cf31f956a2c67b5d504faa4c134fea87217", "e827cffe6c4fb0344da12553d3faa9941d4853347ae36f3ed52804008d0f7d12", "6a17410be22fb451aef5735c60ccde0d1eb7be8d73ca11de5b8b96e7b6be562d", "ad69abf808d588f0537711ee4ab5dd1e011df1813ef24c31f7983210549a030b", "ffcbf2541c6e3acfb37a54f527640ac1b1367e5cc21da8f1b5dfc47214d4e522", "11a90106826a400bb6628cf3dd7b6674dde748910fef9418c61989e909c9b40d", "cb8956af468762bef2862e6626191b06ce3cf48473183b85dac23fb95bab4f2e", "f17f5d129443c8edf7a23355243e71798b3cdcc0bee6959935a03900d1064e25", "b624bfb786355e3d43d8e2ca98fb714d294cfcce03d42930ccccdfda8ad0e700", "d99fa2e837cf8c2028f57bbb1ea7c57b275cd60b0b9fc902916d240bb6a7ef13", "38a6b9f4866f01386e4a5cdd356bea57a1ce2699776bb48bf627a0b2ae061a09", "5280ff755b61db6ba308ab3291ed9e8f0d65f085443353352a1fbe550aa00f30", "7c78c04922860a2312d828a8909f1a92ec7b1cda2486d0a89e1e3d9f11b4ea07", "cba1a3d0dbfd52a3e3e5e06bd59598a292fd055f6440220c47a013a1c0136f01", "971f4f3129beb2583e55c144a503cd36bed3e6683039c22312e286c70b892110", "46c3287345015ce73bcfeeea2c1c6ad148a6f2b8148d1cf12242cc9d950df705", "e227514a7ba26f052b74be7cf889c7585c96b61c4c8a08171e6c01d0a0890329", "f294a8878eff1404798554aeb5741a480f87266434a891c5f2d031dcaf779d0b", "a02b7bfcb8d104cc337181f81981dbdaa764061711da912ad245dc601062c207", "f948319d9bdce7189e7a2d0fad54662fc31d4db65ec17fc7d5f872aff58a3229", "db5f68865a979038cfb6a4c6864417dce91ff1943dae7a20999098f078fc2017", "c0dc0104a386e78f5cd965ccdf1dcb4d85605a652dae4f7202fdfd462e5afa05", "c5ea411c51d5f8fe883169bd0f19fc9a0f679e9ab5db2af8843b6b2d4017d416", "72d02a4694425ef40a39dc2cd9098df56db3f74a23b2a52d433d84023f31ca05", "e208e6e9a5c813524fc8a5e276fed246a59296c99c205e44f5a33290ede46307", "5ecf39f0ae62643215e4df6a201dde895d03ae81c09ab4fd7b72b7398a450f12", "fbf03f846147b4bd911f081032f0e83a9ec3d5a1684b73455b66ecae576e3a1b", "d524bbb6bc1e0354ad38f1a31b0c51e0f437eca2b7aa22f1f2d0d33999c75f22", "8e2f969f2a008bca4d18144cd64ace3c247acef052197dc8c726c3ef82fc9216", "bc0aed2bd28be572d9acbbbd853b1b388b07e952ecde823e66b088e568380318", "205f2a6a4df0f97c7316a33f3d3a1f90e8c90612beb6c57d805889f666d48308", "2b2e0c6dffd6ee44dfd5abbb00b56149139dc0a36f7a364789c72673ebdab121", "1762c0393f65e2e4501de1a79f80f6a8901ece343ef4c35fbfd3548061750c1b", "a4f6818b7bb3d6726844ff7490796b6bda6dd6261c9729ef7b5fbe920fda5918", "2a0adde44ed2522a1ec844e0782130f9f6eb7244151225ed83e1bb46e03e4625", "eb62864d8fc13e42ade611b98c3a4b9bbce97c10ba197ae03583276a7d437218", "5ecee72035d75c94af1b005f98d2cba566502c23a5b72158352aa1b3ae4da90b", "e6d7896131f50c43a44b2eb896bfa8b35b210f7b01300cc40f7276625e993e26", "9cf88658f964ec11a896656e9499b3fd795fe56929c331a43d24acf86ff91829", "259ea41c655dd792759ce7c83244cb28248fccc4bb60d9ea04159cd0dd740018", "6e1dadd3701c4fcb0287f0da2356577e9b6183c468445158e2e6a7ef77e05828", "0433c68f11b980f1e23f1ea0658bf5b704a645200e57ce79b3206d3442118304", "7819c20589291b768ae047231c258f525f601db3a776d165d8504eccb457bf26", "eef7ce831c16d9e4f85e2b6bcdc929669e5d3baf4bd6f3d36658d6aaa025f016", "252c7a218bfd24d1f0b158933abe35fe61da1643f92b0e43270f99e2e5b5ec0f", "16046fe7a01750074f25e90e5ea013c3e7515b198fbaa4ee978a81ef2f6ee11e", "dff60190bf42981b4bd87767215b142599d3c20e6f70c96fc9d2ba0ac874431f", "237e75818240db0dde0dce1ab8eec45fa72462d61c7c94b3603179368e778211", "9a1563a982b1506abf3762ebba2dfeeb2d789f2da81eaaaab78ce0551aeb1124", "ffa838964b4665297ec49a65cfb8705523644d2533fefca2921cad12027ce914", "141e16f5c733b3020666b6dc2406bc6e024e181892f31bd2c5eb8b7f0a1cb304", "6a14878bad098c8c2c524f44f6c319c3ca32d2515b9e3adcca624c8c1c306b2c", "a366fd1004faaaeccbabcdd3e8a353445998cf65cb97dd0dc7feff225f18c70a", "f64fa95f8ea22cc37cb5bf55b9b14202a4362ffaf971dec187eb5a7de26f8918", "871117bca2a71252b4573ea2224d894468e94cf54d08078a985f71f792bf2415", "f6103ad87ed5d36f384aef6fc0c01b718c93c653554f5295011a561398a04f0c", "4219b16d0d6721c6d01b0becb82731bdde63210c6b9422052cb9f01332e6c00a", "26f0f50fae359f4a7c6efb99f9eb1c750ef1ac6884046d5f10dce650eb43262a", "68b3ba9aad1b8c9657efdafd4963941e9463476602ac8c5c522ff2565e9a5b25", "148fee6e326c2b2a21fb5fe7c54f7434e2eed88a8df5f38cb51edcdfb322be14", "e0ab1a832000a19ae1252dbb7aacf7e10ba07521b00f10858a2a8971e8caf72f", "c807b983ec17ed75e6cfbe68c8d0f3a054595998f2015a7b01f99c4c22b5d60f", "576d673f215e47ac00d08ead512c6df90703f222238ba9f4b717d8d113db2815", "2453a4069e246bd117cf44f37bee26b69742c7ed4e017ffbae1b2cee61e7552a", "19cd32a922eb1c05ec539c474d967033fd6dc4b559a3a3bd45b0a7214714f428", "a75d0481c2a99bf39a97c5b42d00330364f0c7f647eff37016963c924746d42a", "4adfce8ebe8f9c261ff386b9e9868fc370eb76e2bc8437a58aca08eabc36452c", "69aea7baf9d7de5023bcc3d72d39e571ab7128860c0f9b20dd0f42be2d67bc2a", "7abb2491782aa116849f6d7ecb04c7176793781b8281c1234fedaa0aec125614", "524ec06001368e1b82df7f95b11c84f3755d5f8347db9b36f9a2e460543f9407", "34db155d11ac9195498fe3085f2d27c867826a2f6c8f85fe3ea0027efd3e4b28", "47ac216c160efe503bbdf729c7db748e751092915c347fc14f9a42e38c71e80f", "872fc7ff0c4f7e3a56859859028757b043a0956980be1ac2eda8fa604622f91d", "d865a5a53d77f42a6efd6a0d54893565b4a917b4524878b494c9b948a7c2a50b", "f162b6d866262070f02d979e44c14894f217fc7c1784c5b22ea62175effabf2a", "22f855fc357bc41f0c9adc57442c0d683f0da51de01f2c8f3953ce065c4b4d10", "794fc6731c72e22d1e9e616500a73ae66565226629fe521bba22a5246f78360f", "1e67f431e204fead6870b8b58aac75c764efb91ad99eaaf916dd45b144e9f622", "a8acd853fcaf910018512945baf9f37d35af168ba66e208b5f590493c97a722f", "2c010b3a1ba788034faee5d4d612b5f2866e279991d52c6c6f28d28a19ad7e1f", "d0454fd9493356dfadf3d44978dd13dba1584dda6981abaeaf31239b24765405", "47313281aa6a4b8f69a224be2a24efc8ba50ae56b2537ddeea72f52e067e2129", "59105b14c0f1c34b8983ecc182152961378673cea3c19329e93b522a6e939b26", "57376021adf6bab8a6c1a28e81adb94ed0cc44a457a89590e516075985c19f13", "4ce2ccb2f94d569def9ac0027b72ce4a060c854ecd308ecd53c5b10403f72003", "9d69c305ad7f7cc207195f63cbb08051feb2b8f279349563241099cde6dfc118", "22cbfa7f81c0a80abd0ec6fc6c498e74ec21d33ed07a59bca8ef6686f2c2a41d", "b656b9290014ee634353f8c5513366cc5d588d2cb5ffb79b453d1cd0466ec717", "84e3b54e4f8215616a31b987ccd450b41469f142db3ccee212e309304cbb342b", "b0eec49f30df542c1acc000b29b3545a0560e98a04448faca1719cd2ee7c7b26", "46821baea0f012a5ec21b05b13d96209fb5846cd27a3607d5fe64cf9442ef318", "2f294cab76254490f3c966d62f132abb21ca01eecb2bf74bf673a3b582c97509", "dfc7b5ece05d38b8e5fcab048ef691e10680956e556dd0f3fd7a11f9d84fdb04", "c7ee2d7534af7ba2a9b0e43e977a245f90e820edfc4429449198c95b405fd62e", "a8861eccfb95827b9d9611819ec8b0b6dc65d0db88311cff8963977e77ffa818", "8e1d34bdad6985cae0abc9ff4bb714b0855a3ecae5f81f637a6ad0216e660107", "de5c35cad3de35657d4d609d24f4166285f032d170370603c27e4eac572ca41b", "7e270d1b92585e3eaa030ab9fe10619a0e35c2d3b8c62c69ca9c3b94d2691d0a", "af17ff3eaaedfcf5499cb720746bd953dd2feb6da8d98c94367369ed0091a826", "d12c44e67ad37e6a20bab1a6dbf21b548e95a7b4c210d94e89c8d22928f6850a", "f4833abce586025007d389c5a6ad24ccd42b0b3d6b22ec6f62c43c5804ead82b", "7b38373e78ae544e84a9d4ed0a4acb05e94f72d1a17f864c37fef3a11f277b07", "d850cfa959ada79b005ded9e6a79983b392c49469c752f150fdd0c4fd22f6729", "ceb220f425d8e5afc5e836101d8094fac6c8f46f79b64f985c8b0b5b90a21e26", "4c5c470fa44a02e7a8f1f675dac853192bad7a24e5f84e0c5054657972a42920", "c19b2efc96bac9acf5ac2ee4b15d312a2c22d3ef50cc058050f02ac2b4b15301", "8dab4c0b08bda620bb63e412a1e8c885192334f18ef106647a4e1151ffca1915", "fdf9f9c8de6326ccc2e711e2729e576c3c76abe2f34fa8fe54b07264ca818505", "44cbe719767d5177e1f4e4d53322b2c66b21a513328c5697afc0b109078b440e", "c822fad5b98c4d3cd4512c046d79fec31627c298b65d545079a77416e353a601", "9cefed3a32434bdef4c72e22ba98289bc4831934f91cd089d8fc1c1c0ab9fa0a", "c95e5f962f083e3c76843818ea096458ae867bf3f696ec4eb9319e2ee267f013", "9afc1cf3fbedaeb81eef6d4298ad7c3f25883afd9331b115ac89d26e01e74719", "f91275b89dc2d2f55a2bb19f54c29a639b6895b3f19fa4d455371c459e268e1d", "f4478da6a4b738dc92fe5c5794a596dd42659d92485b8511e8b6ec1441ce3b23", "d4578946c19ca9ed67186b9ede9ae3334ab166383c584755c7a49bf6387a3015", "cd4b3f127f17b6d3c4253239330fe9b683a529613fe27c2f53698701b6b71b24", "c70351fab047486a8868b940492e9b66730ce659384eecfa2211feae5b626a15", "239c6738175956aed095a33edc83cf08038aa830a69da53fda1a092e0997c60b", "06f4ffe55ff71b78cf5e78497d2ea525973ef2231fcc0552ec788d1362b50325", "f93adfc53d73675148b79ee2d3c51774412f2af4ccf5814ef276ac2024671e26", "5c9af59018e86e3b717a88b2c08e1b6e9a44b5fe64adc25ac1751c8182eeb312", "4196b9532b071f04bdf27837026beb8b062a7c7de33f9e7bcb5b05d8651bdf07", "2700d1680cdfd84a4941610608bff1bdc330ae8a94be24567c189864b266c616", "3f90fa45595427e189067fc5d1b8bb21cbfc4d54530aa3b78266587d2239f41c", "8c80075af391945307627bbc4a4ea6406bd57608445748ece82ef0bae037f60e", "b0c798a4bd153e9420be8211f4360d79d7c3479316b98b548c416c491e80dc1a", "cf2a0dadea865534d471efb19d4001801e5e5695342c7e198a46abfd51bc2b25", "edc85e19f95f66e8d7f2b49e6d00d0473dac9efedee53cbbee578391ce7b9f05", "cebad61c29ce8a4482287b737a7688325571d045b814a966a7ba5a307503dc0f", "214dda0412bef8e0b1d53b2b056091a9c7355c8dbf2f11048a2f3737fb005828", "219961a17263ae29db21cc32589271ccf6dc3416740daafde9a4d93f0416e817", "d6d68ec08be07fa3f5e85497ba6f5a042a18c5ea543da8f9f6615839d0748f05", "ceef793da479045c207be9f827d10dbba1d1637cf0a2d4100d34bad53d82d32f", "62f191cfd6b0888fa0fd3c31597884b7ccdee6c74a255a4afc0f0f25a4ba532d", "b2e58d8678bb66fc00d02047b985cbe5efa1f0e22c71af9684d67fcb1cad940d", "c3ee9ede913d1987b28eeec5de8cc8c0778d1f6e43c4f7ac28c2e5c681571702", "e7e484487cafa71e9c1231740f64bc662b6794ef6ea376c1989074a56cb42c1d", "912e8b04d865dd91f4548849523c91444ac70ff589ba298ce10678a5816ace2d", "2ba9baa6ff79c7727ad1648c1c7fcc4e9943d8b1a2c68f6c1ef1e70d70877510", "e59707ec253abeb04e6cceaf803dd1b69030f7ac8b916059b0d7d60edacbae26", "f36327129c4a66cf7f976b11c0705bf642740bd90055df4ec1540e6b550f5b03", "448025c0ed6a60edd0fa97eb1f84a1f04c8416eb15268b2a89c24a47dee7132b", "08e26120d9d2937b05d58c08aff93266317f19df353258290da4fb068e0af02f", "bb8668525fef05da280502c1353e0c257dce8cfd53beadde87e4366a5a79dc24", "e6f256845d0b8f9177727723857e9b30314cfc753432ca365c0e6b100d68fd22", "642a784417b01858ffed0ccd9b4967a9e7980facdce7667a07b367fabe63d225", "5ebd45b2dc7e010782a4c51a8ae18bad00c35597010a2107cad5041ffab69329", "d73e8c0e36e5588836bc9be4820e108d008f8399e4a9bacb5a452d4850a72d10", "01b81a331bc0c7818812c3848d382551183b35a16d74df5c8c32d561edb74b1c", "403e3cb57be08aef37dcc8af0a93a6ea8064540c8bcdb76fb34875c3d894be03", "6e420bc668f7b2aeee7e719daa3a7a4471bd04e8bcf24a27e4a5ae07e8c44207", "98baf438da4c655b9d92dc9033ae0f5cd7f0efda9b0d1bb894d08f1ce8620a01", "1282dda3446fb157e236155197def0d309eecb9dde8445f599ead69d4f31d916", "6453a3cf73ab5f3bafe645ce69fcdb612526fa66659e564c783c5600fb3a400f", "a8c1bfdbae2f56d10ccaf89887286c7c3256f7bdba21e98ac3c44578926c642c", "34bd74a58df94ae160f90bb64d202908d95b9dd0d89f02cd7e6bc8ddaf11280f", "a7377899f99a93796cd8901e17357403a900570d869fc49afed5e0e8f4bb281e", "63485fb688def0de08ae284fbc0cb6b7d9a6696e9542eb9328d69de33607f902", "6767b23b636e9b89c8b3ac3614fbdf529b6485cb3fc8ae110b705dbcb9e1fe12", "b54c6a95a349be5a1c09e487b4149111c6ccfbdaec5ec6f8ff82fb21ee894113", "604b619329ec489482dcc4af6f5a02f9ed1418f624f900eca143355127406217", "a556c534da5f5549bceb1ba95535dd57af5fd59011772552d5fea78a02e78a11", "34eae6950d3227d848e7e075aecdb65791306156b6503a89406e5802bfd0e117", "a6f3a081dd622f89f0e8703281052ff2a275507214fed44d3813a5027e5c762a"]
    var groupKeyPairs = groupKeys.toMembershipKeyPairs()
    debug "groupKeyPairs", groupKeyPairs
    var groupIDCommitments = groupKeyPairs.mapIt(it.idCommitment)
    debug "groupIDCommitments", groupIDCommitments
    var expectedRoot = calcMerkleRoot(groupIDCommitments)
    debug "expectedRoot", expectedRoot
   
    # start rln-relay in off-chain mode
    await node.mountRlnRelay(groupOpt = some(groupIDCommitments), memKeyPairOpt = some(groupKeyPairs[index]),  memIndexOpt = some(index), onchainMode = false)
    
    let calculatedRoot = node.wakuRlnRelay.rlnInstance.getMerkleRoot().value().toHex
    debug "calculated root by wakuRlnRelay", calculatedRoot
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
    var rlnInstance = createRLNInstance()
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
    var rlnInstance = createRLNInstance()
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
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true

    # delete the first member 
    var deleted_member_index = uint(0)
    let deletion_success = delete_member(rlnInstance.value, deleted_member_index)
    doAssert(deletion_success)

  test "insertMember rln utils":
    # create an RLN instance which also includes an empty Merkle tree
    var rlnInstance = createRLNInstance()
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
    var rlnInstance = createRLNInstance()
    check:
      rlnInstance.isOk == true
    var rln = rlnInstance.value
    check: 
      rln.removeMember(uint(0))

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
    var rlnInstance = createRLNInstance()
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
    var rlnInstance = createRLNInstance()
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
    var rlnInstance = createRLNInstance()
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
  
  test "create a list of membership keys and construct a Merkle tree based on the list":
    let (list, root) = createMembershipList(100) 
    debug "created membership key list", list
    check: 
      list.len == 200 # two parts for each membership key i.e., one id key and one id commitment
    debug "the Merkle tree root", root
    check:
      root.len == 64
  
  test "check correctness of toMembershipKeyPairs and calcMerkleRoot":
    var groupKeys: seq[string] = @["045a90832558f7b56f3f38f56f70bccba392d84f3f1b64ccba6ba21daaf57a1f", "200be495af932e6f83e384393854fb60ec02245f2d630cbb9c701fc9d25f112e", "2e8718c8db83471a19ade90fa1782a593e89f0e6e1555dfcae02d768c155910d", "54e7f26866aae4af2bf3ba81c9d76516c7c2e26a3aa130ae660f05ea3528691c", "545e00fa9a083c962875831b956c9d0d25d27b10b0b02da7feb7f6f3ad474205", "2c57d1be4785d7bb8341635784e48e6f656ee9574f593298302bb15c5583d22a", "d24e4ff2c21ec63c9148887b2a6bd0c2c5daae4bbe889480778f870afea7a02a", "4c338455697992fa98f45cfeda63d6fc7c384e0aebc6603f646f2ed9ec0df204", "9c2d78394523e90ebdfd407a3fe5c31b3bb30d3061358c9fcda6480e1633cd1c", "bee9f122f9fc1887e134f9fe3a55e60cda416263ce1cdd7802fa96b7b0f52619", "0298173e7f2996bd69b4992ac58927fba845b32a919065230bb4c6b377245c05", "7418e583da831e51fa78a90e033f0fcb676adf82af5d03669a002f61cf3ef22e", "1db9bf1a1fdf04d9c8452d5f6c86214f2dc1cdcc56bb3b5f62bcb50282651c21", "27e0c4c13f6e1deea4f7a574269b5f9567645985a21f15b266bc052a856b581f", "714c1f0f5fc782881d26451b2045d68236addc4a782af90b33d8130d1dc2d310", "c3796a90f73a8fd6e9a2e6702075b5b61bd36377cd3f1fba2e55cca60ddcb103", "3721ee9c258a12a96c6db2bd6b85407c20690616c7868cc40cfb78e9f81bba16", "1f569e32ce5f6b31a186bccdeae0dcf0d870462b1ce65ae83972e6f785fbae1d", "ba0746316fdb3e14ed192f62a23f98debfcd3eabe4ae23251e9ecf15032b8312", "2926e40f2f62941e99dda1b647b688f604f224aee3dccb4976cdfccba24aee0b", "c313bc470095373af1efb21f48f7e85935090c02ca016c04adf5650adb28f90a", "eaa5e761efc64949b88ab7eac0fc5331fa4c0c0e755c396983b7873801b5fd0b", "bc69b2eeddeec3a38571de8ebd5782d2230a67eb537aae250bee648eefe89c04", "2f5d17486c310970ace7805773d7654dd9fbc4c254b61fa4612af9b96ba06b17", "00e8fe8d60db239059667286e00804d60b7a93209fbae65f30965a1df26e9717", "599fdd0300101fe0549303e22bb241c2178275448154e09ea0a2ab85ffd26127", "bafb62cf0f58dd3ca10648d64a81318f73dd5d118e9b11e1c5a46a3f7dacb40d", "121c481780bf68cc3bcb1161f30708baf58ee1f06ae57825804cf3ce95869a2a", "6b120e48b20e704efa239b87f0e457ab260bdea86a2f19fac435874685df2d24", "ac00443f4255d5ebcd778b12bd9f0fd957346013a543145549af1cd8f0e8ef0d", "0f444131b66f1728a3eac51eb71b56ffdeef212e5d61a07f3e18b83672677c2d", "66a1fcb111aaa3263f3ce6a44fd0f2722feae4d1d0c6595a69b4d75d595a6b0a", "e0356a4540c0a63f3db9806cf1872fe3d8739276f83f02de0e2165042b841d01", "8e6ce8380c1505b1f9574817d12b5260bb78e9fff4ef56847346caed04401621", "c276a0e8d1e07b033d8df997d7d3f2fdb23054bc63ccaa50aa96580d3f29361b", "a2af0da6570d64e85bbf6facf95a7cf31f956a2c67b5d504faa4c134fea87217", "e827cffe6c4fb0344da12553d3faa9941d4853347ae36f3ed52804008d0f7d12", "6a17410be22fb451aef5735c60ccde0d1eb7be8d73ca11de5b8b96e7b6be562d", "ad69abf808d588f0537711ee4ab5dd1e011df1813ef24c31f7983210549a030b", "ffcbf2541c6e3acfb37a54f527640ac1b1367e5cc21da8f1b5dfc47214d4e522", "11a90106826a400bb6628cf3dd7b6674dde748910fef9418c61989e909c9b40d", "cb8956af468762bef2862e6626191b06ce3cf48473183b85dac23fb95bab4f2e", "f17f5d129443c8edf7a23355243e71798b3cdcc0bee6959935a03900d1064e25", "b624bfb786355e3d43d8e2ca98fb714d294cfcce03d42930ccccdfda8ad0e700", "d99fa2e837cf8c2028f57bbb1ea7c57b275cd60b0b9fc902916d240bb6a7ef13", "38a6b9f4866f01386e4a5cdd356bea57a1ce2699776bb48bf627a0b2ae061a09", "5280ff755b61db6ba308ab3291ed9e8f0d65f085443353352a1fbe550aa00f30", "7c78c04922860a2312d828a8909f1a92ec7b1cda2486d0a89e1e3d9f11b4ea07", "cba1a3d0dbfd52a3e3e5e06bd59598a292fd055f6440220c47a013a1c0136f01", "971f4f3129beb2583e55c144a503cd36bed3e6683039c22312e286c70b892110", "46c3287345015ce73bcfeeea2c1c6ad148a6f2b8148d1cf12242cc9d950df705", "e227514a7ba26f052b74be7cf889c7585c96b61c4c8a08171e6c01d0a0890329", "f294a8878eff1404798554aeb5741a480f87266434a891c5f2d031dcaf779d0b", "a02b7bfcb8d104cc337181f81981dbdaa764061711da912ad245dc601062c207", "f948319d9bdce7189e7a2d0fad54662fc31d4db65ec17fc7d5f872aff58a3229", "db5f68865a979038cfb6a4c6864417dce91ff1943dae7a20999098f078fc2017", "c0dc0104a386e78f5cd965ccdf1dcb4d85605a652dae4f7202fdfd462e5afa05", "c5ea411c51d5f8fe883169bd0f19fc9a0f679e9ab5db2af8843b6b2d4017d416", "72d02a4694425ef40a39dc2cd9098df56db3f74a23b2a52d433d84023f31ca05", "e208e6e9a5c813524fc8a5e276fed246a59296c99c205e44f5a33290ede46307", "5ecf39f0ae62643215e4df6a201dde895d03ae81c09ab4fd7b72b7398a450f12", "fbf03f846147b4bd911f081032f0e83a9ec3d5a1684b73455b66ecae576e3a1b", "d524bbb6bc1e0354ad38f1a31b0c51e0f437eca2b7aa22f1f2d0d33999c75f22", "8e2f969f2a008bca4d18144cd64ace3c247acef052197dc8c726c3ef82fc9216", "bc0aed2bd28be572d9acbbbd853b1b388b07e952ecde823e66b088e568380318", "205f2a6a4df0f97c7316a33f3d3a1f90e8c90612beb6c57d805889f666d48308", "2b2e0c6dffd6ee44dfd5abbb00b56149139dc0a36f7a364789c72673ebdab121", "1762c0393f65e2e4501de1a79f80f6a8901ece343ef4c35fbfd3548061750c1b", "a4f6818b7bb3d6726844ff7490796b6bda6dd6261c9729ef7b5fbe920fda5918", "2a0adde44ed2522a1ec844e0782130f9f6eb7244151225ed83e1bb46e03e4625", "eb62864d8fc13e42ade611b98c3a4b9bbce97c10ba197ae03583276a7d437218", "5ecee72035d75c94af1b005f98d2cba566502c23a5b72158352aa1b3ae4da90b", "e6d7896131f50c43a44b2eb896bfa8b35b210f7b01300cc40f7276625e993e26", "9cf88658f964ec11a896656e9499b3fd795fe56929c331a43d24acf86ff91829", "259ea41c655dd792759ce7c83244cb28248fccc4bb60d9ea04159cd0dd740018", "6e1dadd3701c4fcb0287f0da2356577e9b6183c468445158e2e6a7ef77e05828", "0433c68f11b980f1e23f1ea0658bf5b704a645200e57ce79b3206d3442118304", "7819c20589291b768ae047231c258f525f601db3a776d165d8504eccb457bf26", "eef7ce831c16d9e4f85e2b6bcdc929669e5d3baf4bd6f3d36658d6aaa025f016", "252c7a218bfd24d1f0b158933abe35fe61da1643f92b0e43270f99e2e5b5ec0f", "16046fe7a01750074f25e90e5ea013c3e7515b198fbaa4ee978a81ef2f6ee11e", "dff60190bf42981b4bd87767215b142599d3c20e6f70c96fc9d2ba0ac874431f", "237e75818240db0dde0dce1ab8eec45fa72462d61c7c94b3603179368e778211", "9a1563a982b1506abf3762ebba2dfeeb2d789f2da81eaaaab78ce0551aeb1124", "ffa838964b4665297ec49a65cfb8705523644d2533fefca2921cad12027ce914", "141e16f5c733b3020666b6dc2406bc6e024e181892f31bd2c5eb8b7f0a1cb304", "6a14878bad098c8c2c524f44f6c319c3ca32d2515b9e3adcca624c8c1c306b2c", "a366fd1004faaaeccbabcdd3e8a353445998cf65cb97dd0dc7feff225f18c70a", "f64fa95f8ea22cc37cb5bf55b9b14202a4362ffaf971dec187eb5a7de26f8918", "871117bca2a71252b4573ea2224d894468e94cf54d08078a985f71f792bf2415", "f6103ad87ed5d36f384aef6fc0c01b718c93c653554f5295011a561398a04f0c", "4219b16d0d6721c6d01b0becb82731bdde63210c6b9422052cb9f01332e6c00a", "26f0f50fae359f4a7c6efb99f9eb1c750ef1ac6884046d5f10dce650eb43262a", "68b3ba9aad1b8c9657efdafd4963941e9463476602ac8c5c522ff2565e9a5b25", "148fee6e326c2b2a21fb5fe7c54f7434e2eed88a8df5f38cb51edcdfb322be14", "e0ab1a832000a19ae1252dbb7aacf7e10ba07521b00f10858a2a8971e8caf72f", "c807b983ec17ed75e6cfbe68c8d0f3a054595998f2015a7b01f99c4c22b5d60f", "576d673f215e47ac00d08ead512c6df90703f222238ba9f4b717d8d113db2815", "2453a4069e246bd117cf44f37bee26b69742c7ed4e017ffbae1b2cee61e7552a", "19cd32a922eb1c05ec539c474d967033fd6dc4b559a3a3bd45b0a7214714f428", "a75d0481c2a99bf39a97c5b42d00330364f0c7f647eff37016963c924746d42a", "4adfce8ebe8f9c261ff386b9e9868fc370eb76e2bc8437a58aca08eabc36452c", "69aea7baf9d7de5023bcc3d72d39e571ab7128860c0f9b20dd0f42be2d67bc2a", "7abb2491782aa116849f6d7ecb04c7176793781b8281c1234fedaa0aec125614", "524ec06001368e1b82df7f95b11c84f3755d5f8347db9b36f9a2e460543f9407", "34db155d11ac9195498fe3085f2d27c867826a2f6c8f85fe3ea0027efd3e4b28", "47ac216c160efe503bbdf729c7db748e751092915c347fc14f9a42e38c71e80f", "872fc7ff0c4f7e3a56859859028757b043a0956980be1ac2eda8fa604622f91d", "d865a5a53d77f42a6efd6a0d54893565b4a917b4524878b494c9b948a7c2a50b", "f162b6d866262070f02d979e44c14894f217fc7c1784c5b22ea62175effabf2a", "22f855fc357bc41f0c9adc57442c0d683f0da51de01f2c8f3953ce065c4b4d10", "794fc6731c72e22d1e9e616500a73ae66565226629fe521bba22a5246f78360f", "1e67f431e204fead6870b8b58aac75c764efb91ad99eaaf916dd45b144e9f622", "a8acd853fcaf910018512945baf9f37d35af168ba66e208b5f590493c97a722f", "2c010b3a1ba788034faee5d4d612b5f2866e279991d52c6c6f28d28a19ad7e1f", "d0454fd9493356dfadf3d44978dd13dba1584dda6981abaeaf31239b24765405", "47313281aa6a4b8f69a224be2a24efc8ba50ae56b2537ddeea72f52e067e2129", "59105b14c0f1c34b8983ecc182152961378673cea3c19329e93b522a6e939b26", "57376021adf6bab8a6c1a28e81adb94ed0cc44a457a89590e516075985c19f13", "4ce2ccb2f94d569def9ac0027b72ce4a060c854ecd308ecd53c5b10403f72003", "9d69c305ad7f7cc207195f63cbb08051feb2b8f279349563241099cde6dfc118", "22cbfa7f81c0a80abd0ec6fc6c498e74ec21d33ed07a59bca8ef6686f2c2a41d", "b656b9290014ee634353f8c5513366cc5d588d2cb5ffb79b453d1cd0466ec717", "84e3b54e4f8215616a31b987ccd450b41469f142db3ccee212e309304cbb342b", "b0eec49f30df542c1acc000b29b3545a0560e98a04448faca1719cd2ee7c7b26", "46821baea0f012a5ec21b05b13d96209fb5846cd27a3607d5fe64cf9442ef318", "2f294cab76254490f3c966d62f132abb21ca01eecb2bf74bf673a3b582c97509", "dfc7b5ece05d38b8e5fcab048ef691e10680956e556dd0f3fd7a11f9d84fdb04", "c7ee2d7534af7ba2a9b0e43e977a245f90e820edfc4429449198c95b405fd62e", "a8861eccfb95827b9d9611819ec8b0b6dc65d0db88311cff8963977e77ffa818", "8e1d34bdad6985cae0abc9ff4bb714b0855a3ecae5f81f637a6ad0216e660107", "de5c35cad3de35657d4d609d24f4166285f032d170370603c27e4eac572ca41b", "7e270d1b92585e3eaa030ab9fe10619a0e35c2d3b8c62c69ca9c3b94d2691d0a", "af17ff3eaaedfcf5499cb720746bd953dd2feb6da8d98c94367369ed0091a826", "d12c44e67ad37e6a20bab1a6dbf21b548e95a7b4c210d94e89c8d22928f6850a", "f4833abce586025007d389c5a6ad24ccd42b0b3d6b22ec6f62c43c5804ead82b", "7b38373e78ae544e84a9d4ed0a4acb05e94f72d1a17f864c37fef3a11f277b07", "d850cfa959ada79b005ded9e6a79983b392c49469c752f150fdd0c4fd22f6729", "ceb220f425d8e5afc5e836101d8094fac6c8f46f79b64f985c8b0b5b90a21e26", "4c5c470fa44a02e7a8f1f675dac853192bad7a24e5f84e0c5054657972a42920", "c19b2efc96bac9acf5ac2ee4b15d312a2c22d3ef50cc058050f02ac2b4b15301", "8dab4c0b08bda620bb63e412a1e8c885192334f18ef106647a4e1151ffca1915", "fdf9f9c8de6326ccc2e711e2729e576c3c76abe2f34fa8fe54b07264ca818505", "44cbe719767d5177e1f4e4d53322b2c66b21a513328c5697afc0b109078b440e", "c822fad5b98c4d3cd4512c046d79fec31627c298b65d545079a77416e353a601", "9cefed3a32434bdef4c72e22ba98289bc4831934f91cd089d8fc1c1c0ab9fa0a", "c95e5f962f083e3c76843818ea096458ae867bf3f696ec4eb9319e2ee267f013", "9afc1cf3fbedaeb81eef6d4298ad7c3f25883afd9331b115ac89d26e01e74719", "f91275b89dc2d2f55a2bb19f54c29a639b6895b3f19fa4d455371c459e268e1d", "f4478da6a4b738dc92fe5c5794a596dd42659d92485b8511e8b6ec1441ce3b23", "d4578946c19ca9ed67186b9ede9ae3334ab166383c584755c7a49bf6387a3015", "cd4b3f127f17b6d3c4253239330fe9b683a529613fe27c2f53698701b6b71b24", "c70351fab047486a8868b940492e9b66730ce659384eecfa2211feae5b626a15", "239c6738175956aed095a33edc83cf08038aa830a69da53fda1a092e0997c60b", "06f4ffe55ff71b78cf5e78497d2ea525973ef2231fcc0552ec788d1362b50325", "f93adfc53d73675148b79ee2d3c51774412f2af4ccf5814ef276ac2024671e26", "5c9af59018e86e3b717a88b2c08e1b6e9a44b5fe64adc25ac1751c8182eeb312", "4196b9532b071f04bdf27837026beb8b062a7c7de33f9e7bcb5b05d8651bdf07", "2700d1680cdfd84a4941610608bff1bdc330ae8a94be24567c189864b266c616", "3f90fa45595427e189067fc5d1b8bb21cbfc4d54530aa3b78266587d2239f41c", "8c80075af391945307627bbc4a4ea6406bd57608445748ece82ef0bae037f60e", "b0c798a4bd153e9420be8211f4360d79d7c3479316b98b548c416c491e80dc1a", "cf2a0dadea865534d471efb19d4001801e5e5695342c7e198a46abfd51bc2b25", "edc85e19f95f66e8d7f2b49e6d00d0473dac9efedee53cbbee578391ce7b9f05", "cebad61c29ce8a4482287b737a7688325571d045b814a966a7ba5a307503dc0f", "214dda0412bef8e0b1d53b2b056091a9c7355c8dbf2f11048a2f3737fb005828", "219961a17263ae29db21cc32589271ccf6dc3416740daafde9a4d93f0416e817", "d6d68ec08be07fa3f5e85497ba6f5a042a18c5ea543da8f9f6615839d0748f05", "ceef793da479045c207be9f827d10dbba1d1637cf0a2d4100d34bad53d82d32f", "62f191cfd6b0888fa0fd3c31597884b7ccdee6c74a255a4afc0f0f25a4ba532d", "b2e58d8678bb66fc00d02047b985cbe5efa1f0e22c71af9684d67fcb1cad940d", "c3ee9ede913d1987b28eeec5de8cc8c0778d1f6e43c4f7ac28c2e5c681571702", "e7e484487cafa71e9c1231740f64bc662b6794ef6ea376c1989074a56cb42c1d", "912e8b04d865dd91f4548849523c91444ac70ff589ba298ce10678a5816ace2d", "2ba9baa6ff79c7727ad1648c1c7fcc4e9943d8b1a2c68f6c1ef1e70d70877510", "e59707ec253abeb04e6cceaf803dd1b69030f7ac8b916059b0d7d60edacbae26", "f36327129c4a66cf7f976b11c0705bf642740bd90055df4ec1540e6b550f5b03", "448025c0ed6a60edd0fa97eb1f84a1f04c8416eb15268b2a89c24a47dee7132b", "08e26120d9d2937b05d58c08aff93266317f19df353258290da4fb068e0af02f", "bb8668525fef05da280502c1353e0c257dce8cfd53beadde87e4366a5a79dc24", "e6f256845d0b8f9177727723857e9b30314cfc753432ca365c0e6b100d68fd22", "642a784417b01858ffed0ccd9b4967a9e7980facdce7667a07b367fabe63d225", "5ebd45b2dc7e010782a4c51a8ae18bad00c35597010a2107cad5041ffab69329", "d73e8c0e36e5588836bc9be4820e108d008f8399e4a9bacb5a452d4850a72d10", "01b81a331bc0c7818812c3848d382551183b35a16d74df5c8c32d561edb74b1c", "403e3cb57be08aef37dcc8af0a93a6ea8064540c8bcdb76fb34875c3d894be03", "6e420bc668f7b2aeee7e719daa3a7a4471bd04e8bcf24a27e4a5ae07e8c44207", "98baf438da4c655b9d92dc9033ae0f5cd7f0efda9b0d1bb894d08f1ce8620a01", "1282dda3446fb157e236155197def0d309eecb9dde8445f599ead69d4f31d916", "6453a3cf73ab5f3bafe645ce69fcdb612526fa66659e564c783c5600fb3a400f", "a8c1bfdbae2f56d10ccaf89887286c7c3256f7bdba21e98ac3c44578926c642c", "34bd74a58df94ae160f90bb64d202908d95b9dd0d89f02cd7e6bc8ddaf11280f", "a7377899f99a93796cd8901e17357403a900570d869fc49afed5e0e8f4bb281e", "63485fb688def0de08ae284fbc0cb6b7d9a6696e9542eb9328d69de33607f902", "6767b23b636e9b89c8b3ac3614fbdf529b6485cb3fc8ae110b705dbcb9e1fe12", "b54c6a95a349be5a1c09e487b4149111c6ccfbdaec5ec6f8ff82fb21ee894113", "604b619329ec489482dcc4af6f5a02f9ed1418f624f900eca143355127406217", "a556c534da5f5549bceb1ba95535dd57af5fd59011772552d5fea78a02e78a11", "34eae6950d3227d848e7e075aecdb65791306156b6503a89406e5802bfd0e117", "a6f3a081dd622f89f0e8703281052ff2a275507214fed44d3813a5027e5c762a"]
    var groupKeyPairs = groupKeys.toMembershipKeyPairs()
    debug "groupKeyPairs", groupKeyPairs
    check: groupKeyPairs.len == 50

    var groupIDCommitments = groupKeyPairs.mapIt(it.idCommitment)
    debug "groupIDCommitments", groupIDCommitments
    check: 
      groupIDCommitments.len == 50

    var expectedRoot = calcMerkleRoot(groupIDCommitments)
    debug "expectedRoot", expectedRoot

    check: expectedRoot == "65b753df62fb9a40575b116ba4138a864c66267357fdfca11db82de8bd73b400"