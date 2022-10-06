{.push raises: [Defect].}

import
  std/[sequtils, tables, times, streams, os, deques],
  chronicles, options, chronos, stint,
  confutils,
  web3, json,
  web3/ethtypes,
  eth/keys,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  stew/results,
  stew/[byteutils, arrayops, endians2],
  rln, 
  waku_rln_relay_constants,
  waku_rln_relay_types,
  waku_rln_relay_metrics,
  ../../utils/time,
  ../../node/[wakunode2_types,config],
  ../../../../../examples/v2/config_chat2,
  ../waku_message

logScope:
  topics = "wakurlnrelayutils"

type MerkleNodeResult* = RlnRelayResult[MerkleNode]
type RateLimitProofResult* = RlnRelayResult[RateLimitProof]
type SpamHandler* = proc(wakuMessage: WakuMessage): void {.gcsafe, closure, raises: [Defect].}
type RegistrationHandler* = proc(txHash: string): void {.gcsafe, closure, raises: [Defect].}

# membership contract interface
contract(MembershipContract):
  proc register(pubkey: Uint256) # external payable
  proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}
  # TODO the followings are to be supported
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])

proc toBuffer*(x: openArray[byte]): Buffer =
  ## converts the input to a Buffer object
  ## the Buffer object is used to communicate data with the rln lib
  var temp = @x
  let output = Buffer(`ptr`: addr(temp[0]), len: uint(temp.len))
  return output

when defined(rln) or (not defined(rln) and not defined(rlnzerokit)):

  proc createRLNInstanceLocal(d: int = MerkleTreeDepth): RLNResult
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
      len: csize_t = uint(pbytes.len)
      parametersBuffer = Buffer(`ptr`: addr(pbytes[0]), len: len)

    # check the parameters.key is not empty
    if (pbytes.len == 0):
      debug "error in parameters.key"
      return err("error in parameters.key")

    # create an instance of RLN
    let res = new_circuit_from_params(merkleDepth, addr parametersBuffer,
        addr rlnInstance)
    # check whether the circuit parameters are generated successfully
    if (res == false):
      debug "error in parameters generation"
      return err("error in parameters generation")
    return ok(rlnInstance)

    
  proc membershipKeyGen*(ctxPtr: RLN[Bn256]): Option[MembershipKeyPair] =
    ## generates a MembershipKeyPair that can be used for the registration into the rln membership contract

    # keysBufferPtr will hold the generated key pairs i.e., secret and public keys
    var
      keysBuffer: Buffer
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
    for (i, x) in secret.mpairs: x = generatedKeys[i]
    for (i, x) in public.mpairs: x = generatedKeys[i+32]

    var
      keypair = MembershipKeyPair(idKey: secret, idCommitment: public)


    return some(keypair)

when defined(rlnzerokit):
  proc createRLNInstanceLocal(d: int = MerkleTreeDepth): RLNResult
    {.raises: [Defect, IOError].} =

    ## generates an instance of RLN
    ## An RLN instance supports both zkSNARKs logics and Merkle tree data structure and operations
    ## d indicates the depth of Merkle tree
    var
      rlnInstance: ptr RLN
      merkleDepth: csize_t = uint(d)
      resourcesPathBuffer = RlnResourceFolder.toOpenArrayByte(0, RlnResourceFolder.high).toBuffer()

    # create an instance of RLN
    let res = new_circuit(merkleDepth, addr resourcesPathBuffer, addr rlnInstance)
    # check whether the circuit parameters are generated successfully
    if (res == false):
      debug "error in parameters generation"
      return err("error in parameters generation")
    return ok(rlnInstance)

    
  proc membershipKeyGen*(ctxPtr: ptr RLN): Option[MembershipKeyPair] =
    ## generates a MembershipKeyPair that can be used for the registration into the rln membership contract

    # keysBufferPtr will hold the generated key pairs i.e., secret and public keys
    var
      keysBuffer: Buffer
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
    for (i, x) in secret.mpairs: x = generatedKeys[i]
    for (i, x) in public.mpairs: x = generatedKeys[i+32]

    var
      keypair = MembershipKeyPair(idKey: secret, idCommitment: public)

    return some(keypair)

proc createRLNInstance*(d: int = MerkleTreeDepth): RLNResult {.raises: [Defect, IOError].} =
  ## Wraps the rln instance creation for metrics
  waku_rln_instance_creation_duration_seconds.nanosecondTime:
    let res = createRLNInstanceLocal(d)
  return res

proc toUInt256*(idCommitment: IDCommitment): UInt256 =
  let pk = UInt256.fromBytesBE(idCommitment)
  return pk

proc toIDCommitment*(idCommitmentUint: UInt256): IDCommitment =
  let pk = IDCommitment(idCommitmentUint.toBytesBE())
  return pk

proc toMembershipIndex(v: UInt256): MembershipIndex =
  let result: MembershipIndex = cast[MembershipIndex](v)
  return result

proc register*(idComm: IDCommitment, ethAccountAddress: Address, ethAccountPrivKey: keys.PrivateKey, ethClientAddress: string, membershipContractAddress: Address, registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)): Future[Result[MembershipIndex, string]] {.async.} =
  # TODO may need to also get eth Account Private Key as PrivateKey
  ## registers the idComm  into the membership contract whose address is in rlnPeer.membershipContractAddress
  
  var web3: Web3
  try: # check if the Ethereum client is reachable
    web3 = await newWeb3(ethClientAddress)
  except:
    return err("could not connect to the Ethereum client")

  web3.defaultAccount = ethAccountAddress
  # set the account private key
  web3.privateKey = some(ethAccountPrivKey)
  #  set the gas price twice the suggested price in order for the fast mining
  let gasPrice = int(await web3.provider.eth_gasPrice()) * 2
  
  # when the private key is set in a web3 instance, the send proc (sender.register(pk).send(MembershipFee))
  # does the signing using the provided key
  # web3.privateKey = some(ethAccountPrivateKey)
  var sender = web3.contractSender(MembershipContract, membershipContractAddress) # creates a Sender object with a web3 field and contract address of type Address

  debug "registering an id commitment", idComm=idComm
  let pk = idComm.toUInt256()

  var txHash: TxHash
  try: # send the registration transaction and check if any error occurs
    txHash = await sender.register(pk).send(value = MembershipFee, gasPrice = gasPrice)
  except ValueError as e:
    return err("registration transaction failed: " & e.msg)

  let tsReceipt = await web3.getMinedTransactionReceipt(txHash)
  
  # the receipt topic holds the hash of signature of the raised events
  let firstTopic = tsReceipt.logs[0].topics[0]
  # the hash of the signature of MemberRegistered(uint256,uint256) event is equal to the following hex value
  if firstTopic[0..65] != "0x5a92c2530f207992057b9c3e544108ffce3beda4a63719f316967c49bf6159d2":
    return err("invalid event signature hash")

  # the arguments of the raised event i.e., MemberRegistered are encoded inside the data field
  # data = pk encoded as 256 bits || index encoded as 256 bits
  let arguments = tsReceipt.logs[0].data
  debug "tx log data", arguments=arguments
  let 
    argumentsBytes = arguments.hexToSeqByte()
    eventIdCommUint = UInt256.fromBytesBE(argumentsBytes[0..31])
    eventIndex =  UInt256.fromBytesBE(argumentsBytes[32..^1])
    eventIdComm = eventIdCommUint.toIDCommitment()
  debug "the identity commitment key extracted from tx log", eventIdComm=eventIdComm
  debug "the index of registered identity commitment key", eventIndex=eventIndex

  if eventIdComm != idComm:
    return err("invalid id commitment key")

  await web3.close()

  if registrationHandler.isSome():
    let handler = registrationHandler.get
    handler(toHex(txHash))
  return ok(toMembershipIndex(eventIndex))

proc register*(rlnPeer: WakuRLNRelay, registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)): Future[RlnRelayResult[bool]] {.async.} =
  ## registers the public key of the rlnPeer which is rlnPeer.membershipKeyPair.publicKey
  ## into the membership contract whose address is in rlnPeer.membershipContractAddress
  let pk = rlnPeer.membershipKeyPair.idCommitment
  let regResult = await register(idComm = pk, ethAccountAddress = rlnPeer.ethAccountAddress, ethAccountPrivKey = rlnPeer.ethAccountPrivateKey.get(), ethClientAddress = rlnPeer.ethClientAddress, membershipContractAddress = rlnPeer.membershipContractAddress, registrationHandler = registrationHandler)
  if regResult.isErr:
    return err(regResult.error())
  return ok(true)

proc appendLength*(input: openArray[byte]): seq[byte] =
  ## returns length prefixed version of the input
  ## with the following format [len<8>|input<var>]
  ## len: 8-byte value that represents the number of bytes in the `input`
  ## len is serialized in little-endian
  ## input: the supplied `input`
  let
    # the length should be serialized in little-endian
    len = toBytes(uint64(input.len), Endianness.littleEndian)
    output = concat(@len, @input)
  return output

when defined(rln) or (not defined(rln) and not defined(rlnzerokit)):
  proc hash*(rlnInstance: RLN[Bn256], data: openArray[byte]): MerkleNode =
    ## a thin layer on top of the Nim wrapper of the Poseidon hasher
    debug "hash input", hashhex = data.toHex()
    var lenPrefData = appendLength(data)
    var
      hashInputBuffer = lenPrefData.toBuffer()
      outputBuffer: Buffer # will holds the hash output

    debug "hash input buffer length", bufflen = hashInputBuffer.len
    let
      hashSuccess = hash(rlnInstance, addr hashInputBuffer, addr outputBuffer)
      output = cast[ptr MerkleNode](outputBuffer.`ptr`)[]

    return output

when defined(rlnzerokit):
  proc hash*(rlnInstance: ptr RLN, data: openArray[byte]): MerkleNode =
    ## a thin layer on top of the Nim wrapper of the Poseidon hasher
    debug "hash input", hashhex = data.toHex()
    var lenPrefData = appendLength(data)
    var
      hashInputBuffer = lenPrefData.toBuffer()
      outputBuffer: Buffer # will holds the hash output

    debug "hash input buffer length", bufflen = hashInputBuffer.len
    let
      hashSuccess = hash(rlnInstance, addr hashInputBuffer, addr outputBuffer)
      output = cast[ptr MerkleNode](outputBuffer.`ptr`)[]

    return output

proc serialize(idKey: IDKey, memIndex: MembershipIndex, epoch: Epoch,
    msg: openArray[byte]): seq[byte] =
  ## a private proc to convert RateLimitProof and the data to a byte seq
  ## this conversion is used in the proofGen proc
  ## the serialization is done as instructed in  https://github.com/kilic/rln/blob/7ac74183f8b69b399e3bc96c1ae8ab61c026dc43/src/public.rs#L146
  ## [ id_key<32> | id_index<8> | epoch<32> | signal_len<8> | signal<var> ]
  let memIndexBytes = toBytes(uint64(memIndex), Endianness.littleEndian)
  let lenPrefMsg = appendLength(msg)
  let output = concat(@idKey, @memIndexBytes, @epoch, lenPrefMsg)
  return output

when defined(rln) or (not defined(rln) and not defined(rlnzerokit)):
  proc proofGen*(rlnInstance: RLN[Bn256], data: openArray[byte],
      memKeys: MembershipKeyPair, memIndex: MembershipIndex,
      epoch: Epoch): RateLimitProofResult =

    # serialize inputs
    let serializedInputs = serialize(idKey = memKeys.idKey,
                                    memIndex = memIndex,
                                    epoch = epoch,
                                    msg = data)
    var inputBuffer = toBuffer(serializedInputs)

    debug "input buffer ", inputBuffer

    # generate the proof
    var proof: Buffer
    waku_rln_proof_generation_duration_seconds.nanosecondTime:
      let proofIsSuccessful = generateProof(rlnInstance, addr inputBuffer, addr proof)
    # check whether the generateProof call is done successfully
    if not proofIsSuccessful:
      return err("could not generate the proof")

    var proofValue = cast[ptr array[416, byte]] (proof.`ptr`)
    let proofBytes: array[416, byte] = proofValue[]
    debug "proof content", proofHex = proofValue[].toHex

    ## parse the proof as |zkSNARKs<256>|root<32>|epoch<32>|share_x<32>|share_y<32>|nullifier<32>|
    let
      proofOffset = 256
      rootOffset = proofOffset + 32
      epochOffset = rootOffset + 32
      shareXOffset = epochOffset + 32
      shareYOffset = shareXOffset + 32
      nullifierOffset = shareYOffset + 32

    var
      zkproof: ZKSNARK
      proofRoot, shareX, shareY: MerkleNode
      epoch: Epoch
      nullifier: Nullifier

    discard zkproof.copyFrom(proofBytes[0..proofOffset-1])
    discard proofRoot.copyFrom(proofBytes[proofOffset..rootOffset-1])
    discard epoch.copyFrom(proofBytes[rootOffset..epochOffset-1])
    discard shareX.copyFrom(proofBytes[epochOffset..shareXOffset-1])
    discard shareY.copyFrom(proofBytes[shareXOffset..shareYOffset-1])
    discard nullifier.copyFrom(proofBytes[shareYOffset..nullifierOffset-1])

    let output = RateLimitProof(proof: zkproof,
                                merkleRoot: proofRoot,
                                epoch: epoch,
                                shareX: shareX,
                                shareY: shareY,
                                nullifier: nullifier)

    return ok(output)

  proc serialize(proof: RateLimitProof, data: openArray[byte]): seq[byte] =
    ## a private proc to convert RateLimitProof and data to a byte seq
    ## this conversion is used in the proof verification proc
    ## the order of serialization is based on https://github.com/kilic/rln/blob/7ac74183f8b69b399e3bc96c1ae8ab61c026dc43/src/public.rs#L205
    ## [ proof<256>| root<32>| epoch<32>| share_x<32>| share_y<32>| nullifier<32> | signal_len<8> | signal<var> ]
    let lenPrefMsg = appendLength(@data)
    var proofBytes = concat(@(proof.proof),
                            @(proof.merkleRoot),
                            @(proof.epoch),
                            @(proof.shareX),
                            @(proof.shareY),
                            @(proof.nullifier),
                            lenPrefMsg)

    return proofBytes

  proc getMerkleRoot*(rlnInstance: RLN[Bn256]): MerkleNodeResult =
    # read the Merkle Tree root after insertion
    var
      root {.noinit.}: Buffer = Buffer()
      rootPtr = addr(root)
      getRootSuccessful = getRoot(rlnInstance, rootPtr)
    if not getRootSuccessful: 
      return err("could not get the root")
    if not root.len == 32:
      return err("wrong output size")

    var rootValue = cast[ptr MerkleNode] (root.`ptr`)[]
    return ok(rootValue)

  proc proofVerify*(rlnInstance: RLN[Bn256], data: openArray[byte], proof: RateLimitProof): RlnRelayResult[bool] =
    var
      proofBytes = serialize(proof, data)
      proofBuffer = proofBytes.toBuffer()
      f = 0.uint32
    trace "serialized proof", proof = proofBytes.toHex()

    let verifyIsSuccessful = verify(rlnInstance, addr proofBuffer, addr f)
    if not verifyIsSuccessful:
      # something went wrong in verification
      return err("could not verify proof")
    # f = 0 means the proof is verified
    if f != 0:
      return ok(false)

    return ok(true)

  proc insertMember*(rlnInstance: RLN[Bn256], idComm: IDCommitment): bool =
    var pkBuffer = toBuffer(idComm)
    let pkBufferPtr = addr pkBuffer

    # add the member to the tree
    var member_is_added = update_next_member(rlnInstance, pkBufferPtr)
    return member_is_added

  proc removeMember*(rlnInstance: RLN[Bn256], index: MembershipIndex): bool =
    let deletion_success = delete_member(rlnInstance, index)
    return deletion_success



when defined(rlnzerokit):
  proc proofGen*(rlnInstance: ptr RLN, data: openArray[byte],
      memKeys: MembershipKeyPair, memIndex: MembershipIndex,
      epoch: Epoch): RateLimitProofResult =

    # serialize inputs
    let serializedInputs = serialize(idKey = memKeys.idKey,
                                    memIndex = memIndex,
                                    epoch = epoch,
                                    msg = data)
    var inputBuffer = toBuffer(serializedInputs)

    debug "input buffer ", inputBuffer

    # generate the proof
    var proof: Buffer
    let proofIsSuccessful = generate_proof(rlnInstance, addr inputBuffer, addr proof)
    # check whether the generate_proof call is done successfully
    if not proofIsSuccessful:
      return err("could not generate the proof")

    var proofValue = cast[ptr array[320, byte]] (proof.`ptr`)
    let proofBytes: array[320, byte] = proofValue[]
    debug "proof content", proofHex = proofValue[].toHex

    ## parse the proof as [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> ]

    let
      proofOffset = 128
      rootOffset = proofOffset + 32
      epochOffset = rootOffset + 32
      shareXOffset = epochOffset + 32
      shareYOffset = shareXOffset + 32
      nullifierOffset = shareYOffset + 32
      rlnIdentifierOffset = nullifierOffset + 32

    var
      zkproof: ZKSNARK
      proofRoot, shareX, shareY: MerkleNode
      epoch: Epoch
      nullifier: Nullifier
      rlnIdentifier: RlnIdentifier

    discard zkproof.copyFrom(proofBytes[0..proofOffset-1])
    discard proofRoot.copyFrom(proofBytes[proofOffset..rootOffset-1])
    discard epoch.copyFrom(proofBytes[rootOffset..epochOffset-1])
    discard shareX.copyFrom(proofBytes[epochOffset..shareXOffset-1])
    discard shareY.copyFrom(proofBytes[shareXOffset..shareYOffset-1])
    discard nullifier.copyFrom(proofBytes[shareYOffset..nullifierOffset-1])
    discard rlnIdentifier.copyFrom(proofBytes[nullifierOffset..rlnIdentifierOffset-1])
    
    let output = RateLimitProof(proof: zkproof,
                                merkleRoot: proofRoot,
                                epoch: epoch,
                                shareX: shareX,
                                shareY: shareY,
                                nullifier: nullifier,
                                rlnIdentifier: rlnIdentifier)

    return ok(output)

  proc serialize(proof: RateLimitProof, data: openArray[byte]): seq[byte] =
    ## a private proc to convert RateLimitProof and data to a byte seq
    ## this conversion is used in the proof verification proc
    ## [ proof<128> | root<32> | epoch<32> | share_x<32> | share_y<32> | nullifier<32> | rln_identifier<32> | signal_len<8> | signal<var> ]
    let lenPrefMsg = appendLength(@data)
    var proofBytes = concat(@(proof.proof),
                            @(proof.merkleRoot),
                            @(proof.epoch),
                            @(proof.shareX),
                            @(proof.shareY),
                            @(proof.nullifier),
                            @(proof.rlnIdentifier),
                            lenPrefMsg)

    return proofBytes

  proc proofVerify*(rlnInstance: ptr RLN, data: openArray[byte], proof: RateLimitProof): RlnRelayResult[bool] =
    var
      proofBytes = serialize(proof, data)
      proofBuffer = proofBytes.toBuffer()
      validProof: bool
    trace "serialized proof", proof = proofBytes.toHex()

    let verifyIsSuccessful = verify(rlnInstance, addr proofBuffer, addr validProof)
    if not verifyIsSuccessful:
      # something went wrong in verification call
      warn "could not verify validity of the proof", proof=proof
      return err("could not verify the proof")

    if not validProof:
      return ok(false)

    return ok(true)

  proc insertMember*(rlnInstance: ptr RLN, idComm: IDCommitment): bool =
    var pkBuffer = toBuffer(idComm)
    let pkBufferPtr = addr pkBuffer

    # add the member to the tree
    var member_is_added = update_next_member(rlnInstance, pkBufferPtr)
    return member_is_added

  proc removeMember*(rlnInstance: ptr RLN, index: MembershipIndex): bool =
    let deletion_success = delete_member(rlnInstance, index)
    return deletion_success

  proc getMerkleRoot*(rlnInstance: ptr RLN): MerkleNodeResult =
    # read the Merkle Tree root after insertion
    var
      root {.noinit.}: Buffer = Buffer()
      rootPtr = addr(root)
      getRootSuccessful = getRoot(rlnInstance, rootPtr)
    if not getRootSuccessful: 
      return err("could not get the root")
    if not root.len == 32:
      return err("wrong output size")

    var rootValue = cast[ptr MerkleNode] (root.`ptr`)[]
    return ok(rootValue)


proc updateValidRootQueue*(wakuRlnRelay: WakuRLNRelay, root: MerkleNode): void =
  ## updates the valid Merkle root queue with the latest root and pops the oldest one when the capacity of `AcceptableRootWindowSize` is reached 
  let overflowCount = wakuRlnRelay.validMerkleRoots.len() - AcceptableRootWindowSize
  if overflowCount >= 0:
    # Delete the oldest `overflowCount` elements in the deque (index 0..`overflowCount`)
    for i in 0..overflowCount:
      wakuRlnRelay.validMerkleRoots.popFirst() 
  # Push the next root into the queue
  wakuRlnRelay.validMerkleRoots.addLast(root)

proc insertMember*(wakuRlnRelay: WakuRLNRelay, idComm: IDCommitment): RlnRelayResult[void] =
  ## inserts a new id commitment into the local merkle tree, and adds the changed root to the 
  ## queue of valid roots
  waku_rln_membership_insertion_duration_seconds.nanosecondTime:
    let actionSucceeded = wakuRlnRelay.rlnInstance.insertMember(idComm)
  if not actionSucceeded:
    return err("could not insert id commitment into the merkle tree")

  let rootAfterUpdate = ?wakuRlnRelay.rlnInstance.getMerkleRoot()
  wakuRlnRelay.updateValidRootQueue(rootAfterUpdate)
  return ok()
  

proc removeMember*(wakuRlnRelay: WakuRLNRelay, index: MembershipIndex): RlnRelayResult[void] =
  ## removes a commitment from the local merkle tree at `index`, and adds the changed root to the
  ## queue of valid roots
  let actionSucceeded = wakuRlnRelay.rlnInstance.removeMember(index)
  if not actionSucceeded:
    return err("could not remove id commitment from the merkle tree")

  let rootAfterUpdate = ?wakuRlnRelay.rlnInstance.getMerkleRoot()
  wakuRlnRelay.updateValidRootQueue(rootAfterUpdate)
  return ok()

proc validateRoot*(wakuRlnRelay: WakuRLNRelay, root: MerkleNode): bool =
  ## Validate against the window of roots stored in wakuRlnRelay.validMerkleRoots
  return root in wakuRlnRelay.validMerkleRoots

proc toMembershipKeyPairs*(groupKeys: seq[(string, string)]): seq[
    MembershipKeyPair] {.raises: [Defect, ValueError].} =
  ## groupKeys is  sequence of membership key tuples in the form of (identity key, identity commitment) all in the hexadecimal format
  ## the toMembershipKeyPairs proc populates a sequence of MembershipKeyPairs using the supplied groupKeys

  var groupKeyPairs = newSeq[MembershipKeyPair]()

  for i in 0..groupKeys.len-1:
    let
      idKey = groupKeys[i][0].hexToByteArray(32)
      idCommitment = groupKeys[i][1].hexToByteArray(32)
    groupKeyPairs.add(MembershipKeyPair(idKey: idKey,
        idCommitment: idCommitment))
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

proc createMembershipList*(n: int): (seq[(string, string)], string) {.raises: [
    Defect, IOError].} =
  ## createMembershipList produces a sequence of membership key pairs in the form of (identity key, id commitment keys) in the hexadecimal format
  ## this proc also returns the root of a Merkle tree constructed out of the identity commitment keys of the generated list
  ## the output of this proc is used to initialize a static group keys (to test waku-rln-relay in the off-chain mode)

  # initialize a Merkle tree
  var rlnInstance = createRLNInstance()
  if not rlnInstance.isOk:
    return (@[], "")
  var rln = rlnInstance.value

  var output = newSeq[(string, string)]()
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

proc rlnRelayStaticSetUp*(rlnRelayMembershipIndex: MembershipIndex): (Option[seq[
    IDCommitment]], Option[MembershipKeyPair], Option[
    MembershipIndex]) {.raises: [Defect, ValueError].} =
  let
    # static group
    groupKeys = StaticGroupKeys
    groupSize = StaticGroupSize

  debug "rln-relay membership index", rlnRelayMembershipIndex

  # validate the user-supplied membership index
  if rlnRelayMembershipIndex < MembershipIndex(0) or rlnRelayMembershipIndex >=
      MembershipIndex(groupSize):
    error "wrong membership index"
    return(none(seq[IDCommitment]), none(MembershipKeyPair), none(MembershipIndex))

  # prepare the outputs from the static group keys
  let
    # create a sequence of MembershipKeyPairs from the group keys (group keys are in string format)
    groupKeyPairs = groupKeys.toMembershipKeyPairs()
    # extract id commitment keys
    groupIDCommitments = groupKeyPairs.mapIt(it.idCommitment)
    groupOpt = some(groupIDCommitments)
    # user selected membership key pair
    memKeyPairOpt = some(groupKeyPairs[rlnRelayMembershipIndex])
    memIndexOpt = some(rlnRelayMembershipIndex)

  return (groupOpt, memKeyPairOpt, memIndexOpt)

proc hasDuplicate*(rlnPeer: WakuRLNRelay, msg: WakuMessage): RlnRelayResult[bool] =
  ## returns true if there is another message in the  `nullifierLog` of the `rlnPeer` with the same
  ## epoch and nullifier as `msg`'s epoch and nullifier but different Shamir secret shares
  ## otherwise, returns false
  ## emits an error string if `KeyError` occurs (never happens, it is just to avoid raising unnecessary `KeyError` exception )

  # extract the proof metadata of the supplied `msg`
  let proofMD = ProofMetadata(nullifier: msg.proof.nullifier,
      shareX: msg.proof.shareX, shareY: msg.proof.shareY)

  # check if the epoch exists
  if not rlnPeer.nullifierLog.hasKey(msg.proof.epoch):
    return ok(false)
  try:
    if rlnPeer.nullifierLog[msg.proof.epoch].contains(proofMD):
      # there is an identical record, ignore rhe mag
      return ok(false)

    # check for a message with the same nullifier but different secret shares
    let matched = rlnPeer.nullifierLog[msg.proof.epoch].filterIt((
        it.nullifier == proofMD.nullifier) and ((it.shareX != proofMD.shareX) or
        (it.shareY != proofMD.shareY)))

    if matched.len != 0:
      # there is a duplicate
      return ok(true)

    # there is no duplicate
    return ok(false)

  except KeyError as e:
    return err("the epoch was not found")

proc updateLog*(rlnPeer: WakuRLNRelay, msg: WakuMessage): RlnRelayResult[bool] =
  ## extracts  the `ProofMetadata` of the supplied messages `msg` and
  ## saves it in the `nullifierLog` of the `rlnPeer`

  let proofMD = ProofMetadata(nullifier: msg.proof.nullifier,
      shareX: msg.proof.shareX, shareY: msg.proof.shareY)
  debug "proof metadata", proofMD = proofMD

  # check if the epoch exists
  if not rlnPeer.nullifierLog.hasKey(msg.proof.epoch):
    rlnPeer.nullifierLog[msg.proof.epoch] = @[proofMD]
    return ok(true)

  try:
    # check if an identical record exists
    if rlnPeer.nullifierLog[msg.proof.epoch].contains(proofMD):
      return ok(true)
    # add proofMD to the log
    rlnPeer.nullifierLog[msg.proof.epoch].add(proofMD)
    return ok(true)
  except KeyError as e:
    return err("the epoch was not found")

proc toEpoch*(t: uint64): Epoch =
  ## converts `t` to `Epoch` in little-endian order
  let bytes = toBytes(t, Endianness.littleEndian)
  debug "bytes", bytes = bytes
  var epoch: Epoch
  discard epoch.copyFrom(bytes)
  return epoch

proc fromEpoch*(epoch: Epoch): uint64 =
  ## decodes bytes of `epoch` (in little-endian) to uint64
  let t = fromBytesLE(uint64, array[32, byte](epoch))
  return t

proc calcEpoch*(t: float64): Epoch =
  ## gets time `t` as `flaot64` with subseconds resolution in the fractional part
  ## and returns its corresponding rln `Epoch` value
  let e = uint64(t/EpochUnitSeconds)
  return toEpoch(e)

proc getCurrentEpoch*(): Epoch =
  ## gets the current rln Epoch time
  return calcEpoch(epochTime())

proc diff*(e1, e2: Epoch): int64 =
  ## returns the difference between the two rln `Epoch`s `e1` and `e2`
  ## i.e., e1 - e2

  # convert epochs to their corresponding unsigned numerical values
  let
    epoch1 = fromEpoch(e1)
    epoch2 = fromEpoch(e2)
  return int64(epoch1) - int64(epoch2)

proc validateMessage*(rlnPeer: WakuRLNRelay, msg: WakuMessage,
    timeOption: Option[float64] = none(float64)): MessageValidationResult =
  ## validate the supplied `msg` based on the waku-rln-relay routing protocol i.e.,
  ## the `msg`'s epoch is within MaxEpochGap of the current epoch
  ## the `msg` has valid rate limit proof
  ## the `msg` does not violate the rate limit
  ## `timeOption` indicates Unix epoch time (fractional part holds sub-seconds)
  ## if `timeOption` is supplied, then the current epoch is calculated based on that

  # track message count for metrics
  waku_rln_messages_total.inc()

  #  checks if the `msg`'s epoch is far from the current epoch
  # it corresponds to the validation of rln external nullifier
  var epoch: Epoch
  if timeOption.isSome():
    epoch = calcEpoch(timeOption.get())
  else:
    # get current rln epoch
    epoch = getCurrentEpoch()

  debug "current epoch", currentEpoch = fromEpoch(epoch)
  let
    msgEpoch = msg.proof.epoch
    # calculate the gaps
    gap = diff(epoch, msgEpoch)

  debug "message epoch", msgEpoch = fromEpoch(msgEpoch)

  # validate the epoch
  if abs(gap) >= MaxEpochGap:
    # message's epoch is too old or too ahead
    # accept messages whose epoch is within +-MaxEpochGap from the current epoch
    debug "invalid message: epoch gap exceeds a threshold", gap = gap,
        payload = string.fromBytes(msg.payload)
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_epoch"])
    return MessageValidationResult.Invalid

  ## TODO: FIXME after resolving this issue https://github.com/status-im/nwaku/issues/1247
  if not rlnPeer.validateRoot(msg.proof.merkleRoot):
    debug "invalid message: provided root does not belong to acceptable window of roots", provided=msg.proof.merkleRoot, validRoots=rlnPeer.validMerkleRoots
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_root"])
  #   return MessageValidationResult.Invalid

  # verify the proof
  let
    contentTopicBytes = msg.contentTopic.toBytes
    input = concat(msg.payload, contentTopicBytes)

  waku_rln_proof_verification_total.inc()
  waku_rln_proof_verification_duration_seconds.nanosecondTime:
    let proofVerificationRes = rlnPeer.rlnInstance.proofVerify(input, msg.proof)

  if proofVerificationRes.isErr():
    waku_rln_errors_total.inc(labelValues=["proof_verification"])
    return MessageValidationResult.Invalid
  if not proofVerificationRes.value():
    # invalid proof
    debug "invalid message: invalid proof", payload = string.fromBytes(msg.payload)
    waku_rln_invalid_messages_total.inc(labelValues=["invalid_proof"])
    return MessageValidationResult.Invalid

  # check if double messaging has happened
  let hasDup = rlnPeer.hasDuplicate(msg)
  if hasDup.isErr():
    waku_rln_errors_total.inc(labelValues=["duplicate_check"])
  elif hasDup.value == true:
    debug "invalid message: message is spam", payload = string.fromBytes(msg.payload)
    waku_rln_spam_messages_total.inc()
    return MessageValidationResult.Spam

  # insert the message to the log
  # the result of `updateLog` is discarded because message insertion is guaranteed by the implementation i.e.,
  # it will never error out
  discard rlnPeer.updateLog(msg)
  debug "message is valid", payload = string.fromBytes(msg.payload)
  let rootIndex = rlnPeer.validMerkleRoots.find(msg.proof.merkleRoot)
  waku_rln_valid_messages_total.observe(rootIndex.toFloat())
  return MessageValidationResult.Valid


proc toRLNSignal*(wakumessage: WakuMessage): seq[byte] =
  ## it is a utility proc that prepares the `data` parameter of the proof generation procedure i.e., `proofGen`  that resides in the current module
  ## it extracts the `contentTopic` and the `payload` of the supplied `wakumessage` and serializes them into a byte sequence
  let
    contentTopicBytes = wakumessage.contentTopic.toBytes
    output = concat(wakumessage.payload, contentTopicBytes)
  return output


proc appendRLNProof*(rlnPeer: WakuRLNRelay, msg: var WakuMessage,
    senderEpochTime: float64): bool =
  ## returns true if it can create and append a `RateLimitProof` to the supplied `msg`
  ## returns false otherwise
  ## `senderEpochTime` indicates the number of seconds passed since Unix epoch. The fractional part holds sub-seconds.
  ## The `epoch` field of `RateLimitProof` is derived from the provided `senderEpochTime` (using `calcEpoch()`)

  let input = msg.toRLNSignal()

  var proof: RateLimitProofResult = proofGen(rlnInstance = rlnPeer.rlnInstance, data = input,
                     memKeys = rlnPeer.membershipKeyPair,
                     memIndex = rlnPeer.membershipIndex,
                     epoch = calcEpoch(senderEpochTime))

  if proof.isErr:
    return false

  msg.proof = proof.value
  return true

proc addAll*(wakuRlnRelay: WakuRLNRelay, list: seq[IDCommitment]): RlnRelayResult[void] =
  # add members to the Merkle tree of the  `rlnInstance`
  for i in 0..list.len-1:
    let member = list[i]
    let memberAdded = wakuRlnRelay.insertMember(member)
    if not memberAdded.isOk():
      return err(memberAdded.error())
  return ok()

# the types of inputs to this handler matches the MemberRegistered event/proc defined in the MembershipContract interface
type RegistrationEventHandler  = proc(pubkey: Uint256, index: Uint256): void {.gcsafe, closure, raises: [Defect].}


proc subscribeToGroupEvents(ethClientUri: string, ethAccountAddress: Address, contractAddress: Address, blockNumber: string = "0x0", handler: RegistrationEventHandler) {.async, gcsafe.} = 
  ## connects to the eth client whose URI is supplied as `ethClientUri`
  ## subscribes to the `MemberRegistered` event emitted from the `MembershipContract` which is available on the supplied `contractAddress`
  ## it collects all the events starting from the given `blockNumber`
  ## for every received event, it calls the `handler`
  
  # connect to the eth client
  let web3 = await newWeb3(ethClientUri)
  # prepare a contract sender to interact with it
  var contractObj = web3.contractSender(MembershipContract, contractAddress) 
  web3.defaultAccount = ethAccountAddress 
  #  set the gas price twice the suggested price in order for the fast mining
  # let gasPrice = int(await web3.provider.eth_gasPrice()) * 2

  # subscribe to the MemberRegistered events
  # TODO can do similarly for deletion events, though it is not yet supported
  discard await contractObj.subscribe(MemberRegistered, %*{"fromBlock": blockNumber, "address": contractAddress}) do(pubkey: Uint256, index: Uint256){.raises: [Defect], gcsafe.}:
    try:
      debug "onRegister", pubkey = pubkey, index = index
      handler(pubkey, index)
    except Exception as err:
      # chronos still raises exceptions which inherit directly from Exception
      doAssert false, err.msg
  do (err: CatchableError):
    echo "Error from subscription: ", err.msg   

proc handleGroupUpdates*(rlnPeer: WakuRLNRelay, handler: RegistrationEventHandler) {.async, gcsafe.} =
  # mounts the supplied handler for the registration events emitting from the membership contract
  await subscribeToGroupEvents(ethClientUri = rlnPeer.ethClientAddress, ethAccountAddress = rlnPeer.ethAccountAddress, contractAddress = rlnPeer.membershipContractAddress, handler = handler) 


proc addRLNRelayValidator*(node: WakuNode, pubsubTopic: string, contentTopic: ContentTopic, spamHandler: Option[SpamHandler] = none(SpamHandler)) =
  ## this procedure is a thin wrapper for the pubsub addValidator method
  ## it sets a validator for the waku messages published on the supplied pubsubTopic and contentTopic 
  ## if contentTopic is empty, then validation takes place for All the messages published on the given pubsubTopic
  ## the message validation logic is according to https://rfc.vac.dev/spec/17/
  proc validator(topic: string, message: messages.Message): Future[pubsub.ValidationResult] {.async.} =
    trace "rln-relay topic validator is called"
    let msg = WakuMessage.init(message.data) 
    if msg.isOk():
      let 
        wakumessage = msg.value()
        payload = string.fromBytes(wakumessage.payload)

      # check the contentTopic
      if (wakumessage.contentTopic != "") and (contentTopic != "") and (wakumessage.contentTopic != contentTopic):
        trace "content topic did not match:", contentTopic=wakumessage.contentTopic, payload=payload
        return pubsub.ValidationResult.Accept

      # validate the message
      let 
        validationRes = node.wakuRlnRelay.validateMessage(wakumessage)
        proof = toHex(wakumessage.proof.proof)
        epoch = fromEpoch(wakumessage.proof.epoch)
        root = toHex(wakumessage.proof.merkleRoot)
        shareX = toHex(wakumessage.proof.shareX)
        shareY = toHex(wakumessage.proof.shareY)
        nullifier = toHex(wakumessage.proof.nullifier)
      case validationRes:
        of Valid:
          debug "message validity is verified, relaying:",  contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
          trace "message validity is verified, relaying:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
          return pubsub.ValidationResult.Accept
        of Invalid:
          debug "message validity could not be verified, discarding:", contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
          trace "message validity could not be verified, discarding:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
          return pubsub.ValidationResult.Reject
        of Spam:
          debug "A spam message is found! yay! discarding:", contentTopic=wakumessage.contentTopic, epoch=epoch, timestamp=wakumessage.timestamp, payload=payload
          trace "A spam message is found! yay! discarding:", proof=proof, root=root, shareX=shareX, shareY=shareY, nullifier=nullifier
          if spamHandler.isSome:
            let handler = spamHandler.get
            handler(wakumessage)
          return pubsub.ValidationResult.Reject          
  # set a validator for the supplied pubsubTopic 
  let pb  = PubSub(node.wakuRelay)
  pb.addValidator(pubsubTopic, validator)

proc mountRlnRelayStatic*(node: WakuNode,
                    group: seq[IDCommitment],
                    memKeyPair: MembershipKeyPair,
                    memIndex: MembershipIndex,
                    pubsubTopic: string,
                    contentTopic: ContentTopic,
                    spamHandler: Option[SpamHandler] = none(SpamHandler)) {.raises: [Defect, IOError].}=
  # TODO return a bool value to indicate the success of the call

  debug "mounting rln-relay in off-chain/static mode"
  # check whether inputs are provided
  # relay protocol is the prerequisite of rln-relay
  if node.wakuRelay.isNil:
    error "WakuRelay protocol is not mounted."
    return
  # check whether the pubsub topic is supported at the relay level
  if pubsubTopic notin node.wakuRelay.defaultTopics:
    error "The relay protocol does not support the configured pubsub topic.", pubsubTopic=pubsubTopic
    return

  debug "rln-relay input validation passed"

  # check the peer's index and the inclusion of user's identity commitment in the group
  doAssert((memKeyPair.idCommitment)  == group[int(memIndex)])

  # create an RLN instance
  var rlnInstance = createRLNInstance()
  doAssert(rlnInstance.isOk)
  var rln = rlnInstance.value

  # create the WakuRLNRelay
  var rlnPeer = WakuRLNRelay(membershipKeyPair: memKeyPair,
    membershipIndex: memIndex,
    rlnInstance: rln, 
    pubsubTopic: pubsubTopic,
    contentTopic: contentTopic)

    # add members to the Merkle tree
  for index in 0..group.len-1:
    let member = group[index]
    let memberAdded = rlnPeer.insertMember(member)
    doAssert(memberAdded.isOk())

  # adds a topic validator for the supplied pubsub topic at the relay protocol
  # messages published on this pubsub topic will be relayed upon a successful validation, otherwise they will be dropped
  # the topic validator checks for the correct non-spamming proof of the message
  node.addRLNRelayValidator(pubsubTopic, contentTopic, spamHandler)
  debug "rln relay topic validator is mounted successfully", pubsubTopic=pubsubTopic, contentTopic=contentTopic

  node.wakuRlnRelay = rlnPeer


proc mountRlnRelayDynamic*(node: WakuNode,
                    ethClientAddr: string = "",
                    ethAccAddr: web3.Address,
                    ethAccountPrivKeyOpt: Option[keys.PrivateKey],
                    memContractAddr:  web3.Address,
                    memKeyPair: Option[MembershipKeyPair] = none(MembershipKeyPair),
                    memIndex: Option[MembershipIndex] = none(MembershipIndex),
                    pubsubTopic: string,
                    contentTopic: ContentTopic,
                    spamHandler: Option[SpamHandler] = none(SpamHandler),
                    registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)) : Future[RlnRelayResult[bool]] {.async.} =
  debug "mounting rln-relay in on-chain/dynamic mode"
  # TODO return a bool value to indicate the success of the call
  # relay protocol is the prerequisite of rln-relay
  if node.wakuRelay.isNil:
    error "WakuRelay protocol is not mounted."
    return err("WakuRelay protocol is not mounted.")
  # check whether the pubsub topic is supported at the relay level
  if pubsubTopic notin node.wakuRelay.defaultTopics:
    error "Wakurelay protocol does not support the configured pubsub topic.", pubsubTopic=pubsubTopic
    return err("WakuRelay protocol does not support the configured pubsub topic.")
  debug "rln-relay input validation passed"

  # create an RLN instance
  var rlnInstance = createRLNInstance()
  doAssert(rlnInstance.isOk)
  var rln = rlnInstance.value

  # prepare rln membership key pair
  var 
    keyPair: MembershipKeyPair
    rlnIndex: MembershipIndex
  if memKeyPair.isNone: # no rln credentials provided
    if ethAccountPrivKeyOpt.isSome: # if an ethereum private key is supplied, then create rln credentials and register to the membership contract
      trace "no rln-relay key is provided, generating one"
      let keyPairOpt = rln.membershipKeyGen()
      doAssert(keyPairOpt.isSome)
      keyPair = keyPairOpt.get()
      # register the rln-relay peer to the membership contract
      waku_rln_registration_duration_seconds.nanosecondTime:
        let regIndexRes = await register(idComm = keyPair.idCommitment, ethAccountAddress = ethAccAddr, ethAccountPrivKey = ethAccountPrivKeyOpt.get(), ethClientAddress = ethClientAddr, membershipContractAddress = memContractAddr, registrationHandler = registrationHandler)
      # check whether registration is done
      if regIndexRes.isErr():
        debug "membership registration failed", err=regIndexRes.error()
        return err("membership registration failed: " & regIndexRes.error())
      rlnIndex = regIndexRes.value
      debug "peer is successfully registered into the membership contract"
    else: # if no eth private key is available, skip registration
      debug "running waku-rln-relay in relay-only mode"
  else:
    debug "Peer is already registered to the membership contract"
    keyPair = memKeyPair.get()
    rlnIndex = memIndex.get()

  # create the WakuRLNRelay
  var rlnPeer = WakuRLNRelay(membershipKeyPair: keyPair,
    membershipIndex: rlnIndex,
    membershipContractAddress: memContractAddr,
    ethClientAddress: ethClientAddr,
    ethAccountAddress: ethAccAddr,
    ethAccountPrivateKey: ethAccountPrivKeyOpt,
    rlnInstance: rln,
    pubsubTopic: pubsubTopic,
    contentTopic: contentTopic)


  proc handler(pubkey: Uint256, index: Uint256) =
    debug "a new key is added", pubkey=pubkey
    # assuming all the members arrive in order
    let pk = pubkey.toIDCommitment()
    let isSuccessful = rlnPeer.insertMember(pk)
    debug "received pk", pk=pk.toHex, index =index
    doAssert(isSuccessful.isOk())

  asyncSpawn rlnPeer.handleGroupUpdates(handler)
  debug "dynamic group management is started"
  # adds a topic validator for the supplied pubsub topic at the relay protocol
  # messages published on this pubsub topic will be relayed upon a successful validation, otherwise they will be dropped
  # the topic validator checks for the correct non-spamming proof of the message
  addRLNRelayValidator(node, pubsubTopic, contentTopic, spamHandler)
  debug "rln relay topic validator is mounted successfully", pubsubTopic=pubsubTopic, contentTopic=contentTopic

  node.wakuRlnRelay = rlnPeer
  return ok(true)

proc readPersistentRlnCredentials*(path: string) : RlnMembershipCredentials {.raises: [Defect, OSError, IOError, Exception].} =
  info "Rln credentials exist in file"
  # With regards to printing the keys, it is purely for debugging purposes so that the user becomes explicitly aware of the current keys in use when nwaku is started.
  # Note that this is only until the RLN contract being used is the one deployed on Goerli testnet.
  # These prints need to omitted once RLN contract is deployed on Ethereum mainnet and using valuable funds for staking.
  waku_rln_membership_credentials_import_duration_seconds.nanosecondTime:
    let entireRlnCredentialsFile = readFile(path)

    let jsonObject = parseJson(entireRlnCredentialsFile)
    let deserializedRlnCredentials = to(jsonObject, RlnMembershipCredentials)
    
  debug "Deserialized Rln credentials", rlnCredentials=deserializedRlnCredentials
  return deserializedRlnCredentials

proc mount(node: WakuNode,
           conf: WakuNodeConf|Chat2Conf,
           spamHandler: Option[SpamHandler] = none(SpamHandler),
           registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)
          ): RlnRelayResult[bool] {.raises: [Defect, ValueError, IOError, CatchableError, Exception].} =
  if not conf.rlnRelayDynamic:
    info " setting up waku-rln-relay in off-chain mode... "
    # set up rln relay inputs
    let (groupOpt, memKeyPairOpt, memIndexOpt) = rlnRelayStaticSetUp(MembershipIndex(conf.rlnRelayMembershipIndex))
    if memIndexOpt.isNone:
      error "failed to mount WakuRLNRelay"
    else:
      # mount rlnrelay in off-chain mode with a static group of users
      node.mountRlnRelayStatic(group = groupOpt.get(), memKeyPair = memKeyPairOpt.get(), memIndex= memIndexOpt.get(), pubsubTopic = conf.rlnRelayPubsubTopic, contentTopic = conf.rlnRelayContentTopic, spamHandler = spamHandler)

      info "membership id key", idkey=memKeyPairOpt.get().idKey.toHex
      info "membership id commitment key", idCommitmentkey=memKeyPairOpt.get().idCommitment.toHex

      # check the correct construction of the tree by comparing the calculated root against the expected root
      # no error should happen as it is already captured in the unit tests
      # TODO have added this check to account for unseen corner cases, will remove it later 
      let 
        rootRes = node.wakuRlnRelay.rlnInstance.getMerkleRoot()
        expectedRoot = StaticGroupMerkleRoot
      
      if rootRes.isErr():
        return err(rootRes.error())
      
      let root = rootRes.value()

      if root.toHex != expectedRoot:
        error "root mismatch: something went wrong not in Merkle tree construction"
      debug "the calculated root", root
      info "WakuRLNRelay is mounted successfully", pubsubtopic=conf.rlnRelayPubsubTopic, contentTopic=conf.rlnRelayContentTopic
      return ok(true)
  else: # mount the rln relay protocol in the on-chain/dynamic mode
    echo " setting up waku-rln-relay in on-chain mode... "
    
    # read related inputs to run rln-relay in on-chain mode and do type conversion when needed
    let 
      ethAccountAddr = web3.fromHex(web3.Address, conf.rlnRelayEthAccountAddress)
      ethClientAddr = conf.rlnRelayEthClientAddress
      ethMemContractAddress = web3.fromHex(web3.Address, conf.rlnRelayEthContractAddress)
    var ethAccountPrivKeyOpt = none(keys.PrivateKey)
    if conf.rlnRelayEthAccountPrivateKey != "":
      ethAccountPrivKeyOpt = some(keys.PrivateKey(SkSecretKey.fromHex(conf.rlnRelayEthAccountPrivateKey).value))
      
    # if the rlnRelayCredPath config option is non-empty, then rln-relay credentials should be persisted
    # if the path does not contain any credential file, then a new set is generated and pesisted in the same path
    # if there is a credential file, then no new credentials are generated, instead the content of the file is read and used to mount rln-relay 
    if conf.rlnRelayCredPath != "": 
      let rlnRelayCredPath = joinPath(conf.rlnRelayCredPath, RlnCredentialsFilename)
      debug "rln-relay credential path", rlnRelayCredPath
      # check if there is an rln-relay credential file in the supplied path
      if fileExists(rlnRelayCredPath): 
        # retrieve rln-relay credential
        var credentials = readPersistentRlnCredentials(rlnRelayCredPath)
        # mount rln-relay with the provided rln-relay credential
        let res =  waitFor node.mountRlnRelayDynamic(memContractAddr = ethMemContractAddress, ethClientAddr = ethClientAddr,
                memKeyPair = some(credentials.membershipKeyPair), memIndex = some(credentials.rlnIndex), ethAccAddr = ethAccountAddr,
                ethAccountPrivKeyOpt = ethAccountPrivKeyOpt, pubsubTopic = conf.rlnRelayPubsubTopic, contentTopic = conf.rlnRelayContentTopic, spamHandler = spamHandler, registrationHandler = registrationHandler)
        if res.isErr:
          return err("dynamic rln-relay could not be mounted: " & res.error())
 
      else: # there is no credential file available in the supplied path
        # mount the rln-relay protocol leaving rln-relay credentials arguments unassigned 
        # this infroms mountRlnRelayDynamic proc that new credentials should be generated and registered to the membership contract
        info "no rln credential is provided"
        let res = waitFor node.mountRlnRelayDynamic(memContractAddr = ethMemContractAddress, ethClientAddr = ethClientAddr,
                  ethAccAddr = ethAccountAddr, ethAccountPrivKeyOpt = ethAccountPrivKeyOpt, pubsubTopic = conf.rlnRelayPubsubTopic,
                  contentTopic = conf.rlnRelayContentTopic, spamHandler = spamHandler, registrationHandler = registrationHandler)  
        if res.isErr:
          return err("dynamic rln-relay could not be mounted: " & res.error())
        # Persist generated credentials
        var rlnMembershipCredentials = 
            RlnMembershipCredentials(membershipKeyPair: node.wakuRlnRelay.membershipKeyPair, rlnIndex: node.wakuRlnRelay.membershipIndex)
        # TODO should be replaced with key-store with proper encryption
        # persist rln credential
        writeFile(rlnRelayCredPath, pretty(%rlnMembershipCredentials))

    else:
      # do not persist or use a persisted rln-relay credential
      # a new credential will be generated during the mount process but will not be persisted
      info "no need to persist or use a persisted rln-relay credential"
      let res = waitFor node.mountRlnRelayDynamic(memContractAddr = ethMemContractAddress, ethClientAddr = ethClientAddr,
                ethAccAddr = ethAccountAddr, ethAccountPrivKeyOpt = ethAccountPrivKeyOpt, pubsubTopic = conf.rlnRelayPubsubTopic,
                contentTopic = conf.rlnRelayContentTopic, spamHandler = spamHandler, registrationHandler = registrationHandler)
      if res.isErr:
        return err("dynamic rln-relay could not be mounted: " & res.error())
    
    return ok(true)


proc mountRlnRelay*(node: WakuNode,
                    conf: WakuNodeConf|Chat2Conf,
                    spamHandler: Option[SpamHandler] = none(SpamHandler),
                    registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)
                   ): RlnRelayResult[bool] {.raises: [Defect, ValueError, IOError, CatchableError, Exception].} =
  waku_rln_relay_mounting_duration_seconds.nanosecondTime:
    let res = mount(
      node,
      conf,
      spamHandler,
      registrationHandler
    )
  
  return res
