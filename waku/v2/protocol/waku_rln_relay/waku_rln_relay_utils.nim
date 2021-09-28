{.push raises: [Defect].}

import 
  std/sequtils,
  chronicles, options, chronos, stint,
  web3,
  stew/results,
  stew/byteutils,
  rln, 
  waku_rln_relay_types

logScope:
  topics = "wakurlnrelayutils"

type RLNResult* = Result[RLN[Bn256], string]
type MerkleNodeResult* = Result[MerkleNode, string]
# membership contract interface
contract(MembershipContract):
  # TODO define a return type of bool for register method to signify a successful registration
  proc register(pubkey: Uint256) # external payable

proc createRLNInstance*(d: int = MERKLE_TREE_DEPTH): RLNResult
  {.raises: [Defect, IOError].} =

  ## generates an instance of RLN 
  ## An RLN instance supports both zkSNARKs logics and Merkle tree data structure and operations
  ## d indicates the depth of Merkle tree 
  var  
    rlnInstance: RLN[Bn256]
    merkleDepth: csize_t = uint(d)
    ## parameters.key contains the prover and verifier keys
    ## to generate this file, clone this repo https://github.com/kilic/rln 
    ## and run the following command in the root directory of the cloned project
    ## cargo run --example export_test_keys
    ## the file is generated separately and copied here
    ## parameters are function of tree depth and poseidon hasher
    ## to generate parameters for a different tree depth, change the tree size in the following line of rln library
    ## https://github.com/kilic/rln/blob/3bbec368a4adc68cd5f9bfae80b17e1bbb4ef373/examples/export_test_keys/main.rs#L4
    ## and then proceed as explained above
    parameters = readFile("waku/v2/protocol/waku_rln_relay/parameters.key")
    pbytes = parameters.toBytes()
    len : csize_t = uint(pbytes.len)
    parametersBuffer = Buffer(`ptr`: addr(pbytes[0]), len: len)

  # check the parameters.key is not empty
  if (pbytes.len == 0):
    debug "error in parameters.key"
    return err("error in parameters.key")
  
  # create an instance of RLN
  let res = new_circuit_from_params(merkleDepth, addr parametersBuffer, addr rlnInstance)
  # check whether the circuit parameters are generated successfully
  if (res == false): 
    debug "error in parameters generation"
    return err("error in parameters generation")
  return ok(rlnInstance)

proc membershipKeyGen*(ctxPtr: RLN[Bn256]): Option[MembershipKeyPair] =
  ## generates a MembershipKeyPair that can be used for the registration into the rln membership contract
    
  # keysBufferPtr will hold the generated key pairs i.e., secret and public keys 
  var 
    keysBuffer : Buffer
    keysBufferPtr = addr(keysBuffer)
    done = key_gen(ctxPtr, keysBufferPtr)  

  # check whether the keys are generated successfully
  if(done == false):
    debug "error in key generation"
    return none(MembershipKeyPair)
    
  var generatedKeys = cast[ptr array[64, byte]](keysBufferPtr.`ptr`)[]
  # the public and secret keys together are 64 bytes
  if (generatedKeys.len != 64):
    debug "the generated keys are invalid"
    return none(MembershipKeyPair)
  
  # TODO define a separate proc to decode the generated keys to the secret and public components
  var 
    secret: array[32, byte] 
    public: array[32, byte]
  for (i,x) in secret.mpairs: x = generatedKeys[i]
  for (i,x) in public.mpairs: x = generatedKeys[i+32]
  
  var 
    keypair = MembershipKeyPair(idKey: secret, idCommitment: public)


  return some(keypair)
proc register*(rlnPeer: WakuRLNRelay): Future[bool] {.async.} =
  ## registers the public key of the rlnPeer which is rlnPeer.membershipKeyPair.publicKey
  ## into the membership contract whose address is in rlnPeer.membershipContractAddress
  let web3 = await newWeb3(rlnPeer.ethClientAddress)
  web3.defaultAccount = rlnPeer.ethAccountAddress
  # when the private key is set in a web3 instance, the send proc (sender.register(pk).send(MembershipFee))
  # does the signing using the provided key
  web3.privateKey = rlnPeer.ethAccountPrivateKey
  var sender = web3.contractSender(MembershipContract, rlnPeer.membershipContractAddress) # creates a Sender object with a web3 field and contract address of type Address
  let pk = cast[UInt256](rlnPeer.membershipKeyPair.idCommitment)
  discard await sender.register(pk).send(MembershipFee)
  # TODO check the receipt and then return true/false
  await web3.close()
  return true 

proc proofGen*(data: seq[byte]): seq[byte] =
  # TODO to implement the actual proof generation logic
  return "proof".toBytes() 

proc proofVrfy*(data, proof: seq[byte]): bool =
  # TODO to implement the actual proof verification logic
  return true

proc insertMember*(rlnInstance: RLN[Bn256], idComm: IDCommitment): bool = 
  var temp = idComm
  var pkBuffer = Buffer(`ptr`: addr(temp[0]), len: 32)
  let pkBufferPtr = addr pkBuffer

  # add the member to the tree
  var member_is_added = update_next_member(rlnInstance, pkBufferPtr)
  return member_is_added

proc removeMember*(rlnInstance: RLN[Bn256], index: MembershipIndex): bool = 
  let deletion_success = delete_member(rlnInstance, index)
  return deletion_success

proc getMerkleRoot*(rlnInstance: RLN[Bn256]): MerkleNodeResult = 
  # read the Merkle Tree root after insertion
  var 
    root {.noinit.} : Buffer = Buffer()
    rootPtr = addr(root)
    get_root_successful = get_root(rlnInstance, rootPtr)
  if (not get_root_successful): return err("could not get the root")
  if (not (root.len == 32)): return err("wrong output size")

  var rootValue = cast[ptr array[32,byte]] (root.`ptr`)
  let merkleNode = rootValue[]
  return ok(merkleNode)

proc toMembershipKeyPairs*(groupKeys: seq[(string, string)]): seq[MembershipKeyPair] {.raises: [Defect, ValueError]} =
  ## groupKeys is  sequence of membership key tuples in the form of (identity key, identity commitment) all in the hexadecimal format
  ## the toMembershipKeyPairs proc populates a sequence of MembershipKeyPairs using the supplied groupKeys
  
  var groupKeyPairs = newSeq[MembershipKeyPair]()
  
  for i in 0..groupKeys.len-1:
    let 
      idKey = groupKeys[i][0].hexToByteArray(32)
      idCommitment = groupKeys[i][1].hexToByteArray(32)
    groupKeyPairs.add(MembershipKeyPair(idKey: idKey, idCommitment: idCommitment))
  return groupKeyPairs

proc calcMerkleRoot*(list: seq[IDCommitment]): string {.raises: [Defect, IOError].} = 
  ## returns the root of the Merkle tree that is computed from the supplied list 
  ## the root is in hexadecimal format
  
  var rlnInstance = createRLNInstance()
  doAssert(rlnInstance.isOk)
  var rln = rlnInstance.value

  # create a Merkle tree 
  for i in 0..list.len-1:
    var member_is_added = false
    member_is_added = rln.insertMember(list[i])
    doAssert(member_is_added)  

  let root = rln.getMerkleRoot().value().toHex  
  return root

proc createMembershipList*(n: int): (seq[(string,string)], string) {.raises: [Defect, IOError].} = 
  ## createMembershipList produces a sequence of membership key pairs in the form of (identity key, id commitment keys) in the hexadecimal format
  ## this proc also returns the root of a Merkle tree constructed out of the identity commitment keys of the generated list
  ## the output of this proc is used to initialize a static group keys (to test waku-rln-relay in the off-chain mode)
  
  # initialize a Merkle tree
  var rlnInstance = createRLNInstance()
  if not rlnInstance.isOk:
    return (@[], "")
  var rln = rlnInstance.value

  var output = newSeq[(string,string)]()
  for i in 0..n-1:

    # generate a key pair
    let keypair = rln.membershipKeyGen()
    doAssert(keypair.isSome())
    
    let keyTuple = (keypair.get().idKey.toHex, keypair.get().idCommitment.toHex)
    output.add(keyTuple)

    # insert the key to the Merkle tree
    let inserted = rln.insertMember(keypair.get().idCommitment)
    if not inserted:
      return (@[], "")
    

  let root = rln.getMerkleRoot().value.toHex
  return (output, root)

proc rlnRelaySetUp*(rlnRelayMemIndex: MembershipIndex): (Option[seq[IDCommitment]],Option[MembershipKeyPair], Option[MembershipIndex]) {.raises:[Defect, ValueError].} =
  let
    # static group
    groupKeys = STATIC_GROUP_KEYS
    groupSize = STATIC_GROUP_SIZE

  debug "rln-relay membership index", rlnRelayMemIndex

  # validate the user-supplied membership index
  if rlnRelayMemIndex < MembershipIndex(0) or rlnRelayMemIndex >= MembershipIndex(groupSize):
    error "wrong membership index"
    return(none(seq[IDCommitment]), none(MembershipKeyPair), none(MembershipIndex))
  
  # prepare the outputs from the static group keys
  let 
    # create a sequence of MembershipKeyPairs from the group keys (group keys are in string format)
    groupKeyPairs = groupKeys.toMembershipKeyPairs()
    # extract id commitment keys
    groupIDCommitments = groupKeyPairs.mapIt(it.idCommitment)
    groupOpt= some(groupIDCommitments)
    # user selected membership key pair
    memKeyPairOpt = some(groupKeyPairs[rlnRelayMemIndex])
    memIndexOpt= some(rlnRelayMemIndex)
    
  return (groupOpt, memKeyPairOpt, memIndexOpt)