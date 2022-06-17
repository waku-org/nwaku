{.push raises: [Defect].}

import
  std/sequtils, tables, times,
  chronicles, options, chronos, stint,
  web3, json,
  eth/keys,
  stew/results,
  stew/[byteutils, arrayops, endians2],
  rln, 
  waku_rln_relay_types,
  ../waku_message

logScope:
  topics = "wakurlnrelayutils"

type RLNResult* = Result[RLN[Bn256], string]
type MerkleNodeResult* = Result[MerkleNode, string]
type RateLimitProofResult* = Result[RateLimitProof, string]
type SpamHandler* = proc(wakuMessage: WakuMessage): void {.gcsafe, closure,
    raises: [Defect].}

# membership contract interface
contract(MembershipContract):
  proc register(pubkey: Uint256) # external payable
  proc MemberRegistered(pubkey: Uint256, index: Uint256) {.event.}
  # TODO the followings are to be supported
  # proc registerBatch(pubkeys: seq[Uint256]) # external payable
  # proc withdraw(secret: Uint256, pubkeyIndex: Uint256, receiver: Address)
  # proc withdrawBatch( secrets: seq[Uint256], pubkeyIndex: seq[Uint256], receiver: seq[Address])

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

proc toUInt256*(idCommitment: IDCommitment): UInt256 =
  let pk = UInt256.fromBytesBE(idCommitment)
  return pk

proc toIDCommitment*(idCommitmentUint: UInt256): IDCommitment =
  let pk = IDCommitment(idCommitmentUint.toBytesBE())
  return pk

proc toMembershipIndex(v: UInt256): MembershipIndex =
  let result: MembershipIndex = cast[MembershipIndex](v)
  return result

proc register*(idComm: IDCommitment, ethAccountAddress: Address, ethClientAddress: string, membershipContractAddress: Address): Future[Result[MembershipIndex, string]] {.async.} =
  # TODO may need to also get eth Account Private Key as PrivateKey
  ## registers the idComm  into the membership contract whose address is in rlnPeer.membershipContractAddress
  let web3 = await newWeb3(ethClientAddress)
  web3.defaultAccount = ethAccountAddress
  
  # when the private key is set in a web3 instance, the send proc (sender.register(pk).send(MEMBERSHIP_FEE))
  # does the signing using the provided key
  # web3.privateKey = some(ethAccountPrivateKey)
  var sender = web3.contractSender(MembershipContract, membershipContractAddress) # creates a Sender object with a web3 field and contract address of type Address

  debug "registering an id commitment", idComm=idComm
  let 
    pk = idComm.toUInt256()
    txHash = await sender.register(pk).send(MEMBERSHIP_FEE)
    tsReceipt = await web3.getMinedTransactionReceipt(txHash)
  
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
  return ok(toMembershipIndex(eventIndex))

proc register*(rlnPeer: WakuRLNRelay): Future[bool] {.async.} =
  ## registers the public key of the rlnPeer which is rlnPeer.membershipKeyPair.publicKey
  ## into the membership contract whose address is in rlnPeer.membershipContractAddress
  let pk = rlnPeer.membershipKeyPair.idCommitment
  discard await register(idComm = pk, ethAccountAddress = rlnPeer.ethAccountAddress, ethClientAddress = rlnPeer.ethClientAddress, membershipContractAddress = rlnPeer.membershipContractAddress )
  
  return true

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

proc toBuffer*(x: openArray[byte]): Buffer =
  ## converts the input to a Buffer object
  ## the Buffer object is used to communicate data with the rln lib
  var temp = @x
  let output = Buffer(`ptr`: addr(temp[0]), len: uint(temp.len))
  return output

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
  let proofIsSuccessful = generate_proof(rlnInstance, addr inputBuffer, addr proof)
  # check whether the generate_proof call is done successfully
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

proc proofVerify*(rlnInstance: RLN[Bn256], data: openArray[byte],
    proof: RateLimitProof): bool =
  var
    proofBytes = serialize(proof, data)
    proofBuffer = proofBytes.toBuffer()
    f = 0.uint32
  trace "serialized proof", proof = proofBytes.toHex()

  let verifyIsSuccessful = verify(rlnInstance, addr proofBuffer, addr f)
  if not verifyIsSuccessful:
    # something went wrong in verification
    return false
  # f = 0 means the proof is verified
  if f == 0:
    return true
  return false

proc insertMember*(rlnInstance: RLN[Bn256], idComm: IDCommitment): bool =
  var pkBuffer = toBuffer(idComm)
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
    root {.noinit.}: Buffer = Buffer()
    rootPtr = addr(root)
    get_root_successful = get_root(rlnInstance, rootPtr)
  if (not get_root_successful): return err("could not get the root")
  if (not (root.len == 32)): return err("wrong output size")

  var rootValue = cast[ptr MerkleNode] (root.`ptr`)[]
  return ok(rootValue)

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

proc rlnRelayStaticSetUp*(rlnRelayMemIndex: MembershipIndex): (Option[seq[
    IDCommitment]], Option[MembershipKeyPair], Option[
    MembershipIndex]) {.raises: [Defect, ValueError].} =
  let
    # static group
    groupKeys = STATIC_GROUP_KEYS
    groupSize = STATIC_GROUP_SIZE

  debug "rln-relay membership index", rlnRelayMemIndex

  # validate the user-supplied membership index
  if rlnRelayMemIndex < MembershipIndex(0) or rlnRelayMemIndex >=
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
    memKeyPairOpt = some(groupKeyPairs[rlnRelayMemIndex])
    memIndexOpt = some(rlnRelayMemIndex)

  return (groupOpt, memKeyPairOpt, memIndexOpt)

proc hasDuplicate*(rlnPeer: WakuRLNRelay, msg: WakuMessage): Result[bool, string] =
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

proc updateLog*(rlnPeer: WakuRLNRelay, msg: WakuMessage): Result[bool, string] =
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
  let e = uint64(t/EPOCH_UNIT_SECONDS)
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
  ## the `msg`'s epoch is within MAX_EPOCH_GAP of the current epoch
  ## the `msg` has valid rate limit proof
  ## the `msg` does not violate the rate limit
  ## `timeOption` indicates Unix epoch time (fractional part holds sub-seconds)
  ## if `timeOption` is supplied, then the current epoch is calculated based on that


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
  if abs(gap) >= MAX_EPOCH_GAP:
    # message's epoch is too old or too ahead
    # accept messages whose epoch is within +-MAX_EPOCH_GAP from the current epoch
    debug "invalid message: epoch gap exceeds a threshold", gap = gap,
        payload = string.fromBytes(msg.payload)
    return MessageValidationResult.Invalid

  # verify the proof
  let
    contentTopicBytes = msg.contentTopic.toBytes
    input = concat(msg.payload, contentTopicBytes)
  if not rlnPeer.rlnInstance.proofVerify(input, msg.proof):
    # invalid proof
    debug "invalid message: invalid proof", payload = string.fromBytes(msg.payload)
    return MessageValidationResult.Invalid

  # check if double messaging has happened
  let hasDup = rlnPeer.hasDuplicate(msg)
  if hasDup.isOk and hasDup.value == true:
    debug "invalid message: message is a spam", payload = string.fromBytes(msg.payload)
    return MessageValidationResult.Spam

  # insert the message to the log
  # the result of `updateLog` is discarded because message insertion is guaranteed by the implementation i.e.,
  # it will never error out
  discard rlnPeer.updateLog(msg)
  debug "message is valid", payload = string.fromBytes(msg.payload)
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

proc addAll*(rlnInstance: RLN[Bn256], list: seq[IDCommitment]): bool =
  # add members to the Merkle tree of the  `rlnInstance`
  for i in 0..list.len-1:
    let member = list[i]
    let member_is_added = rlnInstance.insertMember(member)
    if not member_is_added:
      return false
  return true

# the types of inputs to this handler matches the MemberRegistered event/proc defined in the MembershipContract interface
type RegistrationEventHandler  = proc(pubkey: Uint256, index: Uint256): void {.gcsafe, closure, raises: [Defect].}


proc subscribeToGroupEvents(ethClientUri: string, contractAddress: Address, blockNumber: string = "0x0", handler: RegistrationEventHandler) {.async, gcsafe.} = 
  ## connects to the eth client whose URI is supplied as `ethClientUri`
  ## subscribes to the `MemberRegistered` event emitted from the `MembershipContract` which is available on the supplied `contractAddress`
  ## it collects all the events starting from the given `blockNumber`
  ## for every received event, it calls the `handler`
  
  # connect to the eth client
  let web3 = await newWeb3(ETH_CLIENT)
  # prepare a contract sender to interact with it
  var contractObj = web3.contractSender(MembershipContract, contractAddress) 

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
  await subscribeToGroupEvents(ethClientUri = rlnPeer.ethClientAddress, contractAddress = rlnPeer.membershipContractAddress, handler = handler) 