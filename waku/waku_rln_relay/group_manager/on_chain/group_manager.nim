{.push raises: [].}

import
  os,
  web3,
  web3/eth_api_types,
  web3/primitives,
  eth/keys as keys,
  chronicles,
  nimcrypto/keccak as keccak,
  stint,
  json,
  std/[strutils, tables, algorithm, strformat],
  stew/[byteutils, arrayops],
  sequtils

import
  ../../../waku_keystore,
  ../../rln,
  ../../rln/rln_interface,
  ../../conversion_utils,
  ../group_manager_base,
  ./retry_wrapper,
  ./rpc_wrapper

export group_manager_base

logScope:
  topics = "waku rln_relay onchain_group_manager"

type
  WakuRlnContractWithSender = Sender[WakuRlnContract]
  OnchainGroupManager* = ref object of GroupManager
    ethClientUrls*: seq[string]
    ethPrivateKey*: Option[string]
    ethContractAddress*: string
    ethRpc*: Option[Web3]
    wakuRlnContract*: Option[WakuRlnContractWithSender]
    registrationTxHash*: Option[TxHash]
    chainId*: UInt256
    keystorePath*: Option[string]
    keystorePassword*: Option[string]
    registrationHandler*: Option[RegistrationHandler]
    latestProcessedBlock*: BlockNumber
    merkleProofCache*: seq[byte]

# The below code is not working with the latest web3 version due to chainId being null (specifically on linea-sepolia)
# TODO: find better solution than this custom sendEthCallWithoutParams call

proc fetchMerkleProofElements*(
    g: OnchainGroupManager
): Future[Result[seq[byte], string]] {.async.} =
  try:
    let membershipIndex = g.membershipIndex.get()
    let index40 = stuint(membershipIndex, 40)

    let methodSig = "getMerkleProof(uint40)"
    var paddedParam = newSeq[byte](32)
    let indexBytes = index40.toBytesBE()
    for i in 0 ..< min(indexBytes.len, paddedParam.len):
      paddedParam[paddedParam.len - indexBytes.len + i] = indexBytes[i]

    let response = await sendEthCallWithParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = methodSig,
      params = paddedParam,
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
    )

    return response
  except CatchableError:
    error "Failed to fetch Merkle proof elements", error = getCurrentExceptionMsg()
    return err("Failed to fetch merkle proof elements: " & getCurrentExceptionMsg())

proc fetchMerkleRoot*(
    g: OnchainGroupManager
): Future[Result[UInt256, string]] {.async.} =
  try:
    let merkleRoot = await sendEthCallWithoutParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = "root()",
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
    )
    return merkleRoot
  except CatchableError:
    error "Failed to fetch Merkle root", error = getCurrentExceptionMsg()
    return err("Failed to fetch merkle root: " & getCurrentExceptionMsg())

proc fetchNextFreeIndex*(
    g: OnchainGroupManager
): Future[Result[UInt256, string]] {.async.} =
  try:
    let nextFreeIndex = await sendEthCallWithoutParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = "nextFreeIndex()",
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
    )
    return nextFreeIndex
  except CatchableError:
    error "Failed to fetch next free index", error = getCurrentExceptionMsg()
    return err("Failed to fetch next free index: " & getCurrentExceptionMsg())

proc fetchMembershipStatus*(
    g: OnchainGroupManager, idCommitment: IDCommitment
): Future[Result[bool, string]] {.async.} =
  try:
    let params = idCommitment.reversed()
    let responseBytes = (
      await sendEthCallWithParams(
        ethRpc = g.ethRpc.get(),
        functionSignature = "isInMembershipSet(uint256)",
        params = params,
        fromAddress = g.ethRpc.get().defaultAccount,
        toAddress = fromHex(Address, g.ethContractAddress),
        chainId = g.chainId,
      )
    ).valueOr:
      return err("Failed to check membership: " & error)

    return ok(responseBytes.len == 32 and responseBytes[^1] == 1'u8)
  except CatchableError:
    error "Failed to fetch membership set membership", error = getCurrentExceptionMsg()
    return err("Failed to fetch membership set membership: " & getCurrentExceptionMsg())

proc fetchMaxMembershipRateLimit*(
    g: OnchainGroupManager
): Future[Result[UInt256, string]] {.async.} =
  try:
    let maxMembershipRateLimit = await sendEthCallWithoutParams(
      ethRpc = g.ethRpc.get(),
      functionSignature = "maxMembershipRateLimit()",
      fromAddress = g.ethRpc.get().defaultAccount,
      toAddress = fromHex(Address, g.ethContractAddress),
      chainId = g.chainId,
    )
    return maxMembershipRateLimit
  except CatchableError:
    error "Failed to fetch max membership rate limit", error = getCurrentExceptionMsg()
    return err("Failed to fetch max membership rate limit: " & getCurrentExceptionMsg())

template initializedGuard(g: OnchainGroupManager): untyped =
  if not g.initialized:
    raise newException(CatchableError, "OnchainGroupManager is not initialized")

template retryWrapper(
    g: OnchainGroupManager, res: auto, errStr: string, body: untyped
): auto =
  retryWrapper(res, RetryStrategy.new(), errStr, g.onFatalErrorAction):
    body

proc updateRoots*(g: OnchainGroupManager): Future[bool] {.async.} =
  let rootRes = (await g.fetchMerkleRoot()).valueOr:
    return false

  let merkleRoot = UInt256ToField(rootRes)

  if g.validRoots.len == 0:
    g.validRoots.addLast(merkleRoot)
    return true

  if g.validRoots[g.validRoots.len - 1] != merkleRoot:
    if g.validRoots.len > AcceptableRootWindowSize:
      discard g.validRoots.popFirst()
    g.validRoots.addLast(merkleRoot)
    return true

  return false

proc trackRootChanges*(g: OnchainGroupManager) {.async: (raises: [CatchableError]).} =
  try:
    initializedGuard(g)
    const rpcDelay = 5.seconds

    while true:
      await sleepAsync(rpcDelay)
      let rootUpdated = await g.updateRoots()

      if rootUpdated:
        ## The membership set on-chain has changed (some new members have joined or some members have left)
        if g.membershipIndex.isSome():
          ## A membership index exists only if the node has registered with RLN.
          ## Non-registered nodes cannot have Merkle proof elements.
          let proofResult = await g.fetchMerkleProofElements()
          if proofResult.isErr():
            error "Failed to fetch Merkle proof", error = proofResult.error
          else:
            g.merkleProofCache = proofResult.get()

        let nextFreeIndex = (await g.fetchNextFreeIndex()).valueOr:
          error "Failed to fetch next free index", error = error
          raise
            newException(CatchableError, "Failed to fetch next free index: " & error)

        let memberCount = cast[int64](nextFreeIndex)
        waku_rln_number_registered_memberships.set(float64(memberCount))
  except CatchableError:
    error "Fatal error in trackRootChanges", error = getCurrentExceptionMsg()

method register*(
    g: OnchainGroupManager, rateCommitment: RateCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  try:
    let leaf = rateCommitment.toLeaf().get()
    if g.registerCb.isSome():
      let idx = g.latestIndex
      info "registering member via callback", rateCommitment = leaf, index = idx
      await g.registerCb.get()(@[Membership(rateCommitment: leaf, index: idx)])
    g.latestIndex.inc()
  except CatchableError:
    raise newException(ValueError, getCurrentExceptionMsg())

method register*(
    g: OnchainGroupManager,
    identityCredential: IdentityCredential,
    userMessageLimit: UserMessageLimit,
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

  let ethRpc = g.ethRpc.get()
  let wakuRlnContract = g.wakuRlnContract.get()

  var gasPrice: int
  g.retryWrapper(gasPrice, "Failed to get gas price"):
    int(await ethRpc.provider.eth_gasPrice()) * 2
  let idCommitmentHex = identityCredential.idCommitment.inHex()
  info "identityCredential idCommitmentHex", idCommitment = idCommitmentHex
  let idCommitment = identityCredential.idCommitment.toUInt256()
  let idCommitmentsToErase: seq[UInt256] = @[]
  info "registering the member",
    idCommitment = idCommitment,
    userMessageLimit = userMessageLimit,
    idCommitmentsToErase = idCommitmentsToErase
  var txHash: TxHash
  g.retryWrapper(txHash, "Failed to register the member"):
    await wakuRlnContract
    .register(idCommitment, userMessageLimit.stuint(32), idCommitmentsToErase)
    .send(gasPrice = gasPrice)

  # wait for the transaction to be mined
  var tsReceipt: ReceiptObject
  g.retryWrapper(tsReceipt, "Failed to get the transaction receipt"):
    await ethRpc.getMinedTransactionReceipt(txHash)
  info "registration transaction mined", txHash = txHash
  g.registrationTxHash = some(txHash)
  # the receipt topic holds the hash of signature of the raised events
  # TODO: make this robust. search within the event list for the event
  info "ts receipt", receipt = tsReceipt[]

  if tsReceipt.status.isNone():
    raise newException(ValueError, "Transaction failed: status is None")
  if tsReceipt.status.get() != 1.Quantity:
    raise newException(
      ValueError, "Transaction failed with status: " & $tsReceipt.status.get()
    )

  ## Extract MembershipRegistered event from transaction logs (third event)
  let thirdTopic = tsReceipt.logs[2].topics[0]
  info "third topic", thirdTopic = thirdTopic
  if thirdTopic !=
      cast[FixedBytes[32]](keccak.keccak256.digest(
        "MembershipRegistered(uint256,uint256,uint32)"
      ).data):
    raise newException(ValueError, "register: unexpected event signature")

  ## Parse MembershipRegistered event data: rateCommitment(256) || membershipRateLimit(256) || index(32)
  let arguments = tsReceipt.logs[2].data
  info "tx log data", arguments = arguments
  let
    ## Extract membership index from transaction log data (big endian)
    membershipIndex = UInt256.fromBytesBE(arguments[64 .. 95])

  trace "parsed membershipIndex", membershipIndex
  g.userMessageLimit = some(userMessageLimit)
  g.membershipIndex = some(membershipIndex.toMembershipIndex())
  g.idCredentials = some(identityCredential)

  let rateCommitment = RateCommitment(
      idCommitment: identityCredential.idCommitment, userMessageLimit: userMessageLimit
    )
    .toLeaf()
    .get()

  if g.registerCb.isSome():
    let member = Membership(rateCommitment: rateCommitment, index: g.latestIndex)
    await g.registerCb.get()(@[member])
  g.latestIndex.inc()

  return

method withdraw*(
    g: OnchainGroupManager, idCommitment: IDCommitment
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g) # TODO: after slashing is enabled on the contract

method withdrawBatch*(
    g: OnchainGroupManager, idCommitments: seq[IDCommitment]
): Future[void] {.async: (raises: [Exception]).} =
  initializedGuard(g)

proc getRootFromProofAndIndex(
    g: OnchainGroupManager, elements: seq[byte], bits: seq[byte]
): GroupManagerResult[array[32, byte]] =
  # this is a helper function to get root from merkle proof elements and index
  # it's currently not used anywhere, but can be used to verify the root from the proof and index
  # Compute leaf hash from idCommitment and messageLimit
  let messageLimitField = uint64ToField(g.userMessageLimit.get())
  var hash = poseidon(@[g.idCredentials.get().idCommitment, @messageLimitField]).valueOr:
    return err("Failed to compute leaf hash: " & error)

  for i in 0 ..< bits.len:
    let sibling = elements[i * 32 .. (i + 1) * 32 - 1]

    let hashRes =
      if bits[i] == 0:
        poseidon(@[@hash, sibling])
      else:
        poseidon(@[sibling, @hash])

    hash = hashRes.valueOr:
      return err("Failed to compute poseidon hash: " & error)

  return ok(hash)

method generateProof*(
    g: OnchainGroupManager,
    data: seq[byte],
    epoch: Epoch,
    messageId: MessageId,
    rlnIdentifier = DefaultRlnIdentifier,
): GroupManagerResult[RateLimitProof] {.gcsafe, raises: [].} =
  ## Generates an RLN proof using the cached Merkle proof and custom witness
  # Ensure identity credentials and membership index are set
  if g.idCredentials.isNone():
    return err("identity credentials are not set")
  if g.membershipIndex.isNone():
    return err("membership index is not set")
  if g.userMessageLimit.isNone():
    return err("user message limit is not set")
  if (g.merkleProofCache.len mod 32) != 0:
    return err("Invalid merkle proof cache length")

  # Convert identity secret to CFr using FFI2
  var identitySecretVec = newVec(g.idCredentials.get().idSecretHash)
  var identitySecretCFr: CFr
  if not ffi_hash_to_field_le(addr identitySecretVec, addr identitySecretCFr):
    freeVec(identitySecretVec)
    return err("Failed to convert identity secret to field element")
  freeVec(identitySecretVec)

  # Convert user message limit to CFr
  var userMessageLimitCFr: CFr
  if not ffi_cfr_from_uint(g.userMessageLimit.get(), addr userMessageLimitCFr):
    return err("Failed to convert user message limit to field element")

  # Convert message ID to CFr
  var messageIdCFr: CFr
  if not ffi_cfr_from_uint(messageId, addr messageIdCFr):
    return err("Failed to convert message ID to field element")

  # Convert merkle proof path elements to CFr
  var pathElementsCFr: seq[CFr]
  for i in 0 ..< g.merkleProofCache.len div 32:
    let chunk = g.merkleProofCache[i * 32 .. (i + 1) * 32 - 1]
    var reversedChunk = chunk.reversed()
    var elementVec = newVec(reversedChunk)
    var cfr: CFr
    if not ffi_hash_to_field_le(addr elementVec, addr cfr):
      freeVec(elementVec)
      return err("Failed to convert path element to field element")
    pathElementsCFr.add(cfr)
    freeVec(elementVec)

  # Compute external nullifier using poseidon
  let extNullifierBytes = poseidon(@[@(epoch), @(rlnIdentifier)]).valueOr:
    return err("Failed to compute external nullifier: " & error)

  var extNullifierVec = newVec(@extNullifierBytes)
  var externalNullifierCFr: CFr
  if not ffi_hash_to_field_le(addr extNullifierVec, addr externalNullifierCFr):
    freeVec(extNullifierVec)
    return err("Failed to convert external nullifier to field element")
  freeVec(extNullifierVec)

  # Compute x (Shamir share x-coordinate) from keccak hash of data
  let xHash = keccak.keccak256.digest(data)
  var xBytes: seq[byte]
  for b in xHash.data:
    xBytes.add(b)
  var xVec = newVec(xBytes)
  var xCFr: CFr
  if not ffi_hash_to_field_le(addr xVec, addr xCFr):
    freeVec(xVec)
    return err("Failed to convert x coordinate to field element")
  freeVec(xVec)

  # Build witness input struct using FFI2
  let identityPathIndex = uint64ToIndex(g.membershipIndex.get(), 20)
  var witness = ffi_RLNWitnessInput(
    identity_secret: identitySecretCFr,
    user_message_limit: userMessageLimitCFr,
    message_id: messageIdCFr,
    path_elements: newVec(pathElementsCFr),
    identity_path_index: newVec(identityPathIndex),
    x: xCFr,
    external_nullifier: externalNullifierCFr,
  )

  # Prepare signal (the data being proven)
  var signalVec = newVec(data)

  # Generate proof using FFI2 API
  var ffi2Proof: ffi_RLNProof
  let proofSuccess =
    ffi_generate_rln_proof(g.rlnInstance, addr witness, addr signalVec, addr ffi2Proof)

  # Clean up allocated memory
  freeVec(witness.path_elements)
  freeVec(witness.identity_path_index)
  freeVec(signalVec)

  if not proofSuccess:
    return err("Failed to generate proof")

  # Convert ffi_RLNProof to RateLimitProof format
  # Serialize CFr fields to bytes
  var proofVec: Vec[uint8]
  var rootVec: Vec[uint8]
  var extNullVec: Vec[uint8]
  var shareXVec: Vec[uint8]
  var shareYVec: Vec[uint8]
  var nullifierVec: Vec[uint8]

  if not ffi_cfr_serialize(addr ffi2Proof.root, addr rootVec):
    return err("Failed to serialize proof root")
  if not ffi_cfr_serialize(addr ffi2Proof.external_nullifier, addr extNullVec):
    freeVec(rootVec)
    return err("Failed to serialize external nullifier")
  if not ffi_cfr_serialize(addr ffi2Proof.share_x, addr shareXVec):
    freeVec(rootVec)
    freeVec(extNullVec)
    return err("Failed to serialize share_x")
  if not ffi_cfr_serialize(addr ffi2Proof.share_y, addr shareYVec):
    freeVec(rootVec)
    freeVec(extNullVec)
    freeVec(shareXVec)
    return err("Failed to serialize share_y")
  if not ffi_cfr_serialize(addr ffi2Proof.nullifier, addr nullifierVec):
    freeVec(rootVec)
    freeVec(extNullVec)
    freeVec(shareXVec)
    freeVec(shareYVec)
    return err("Failed to serialize nullifier")

  # Convert Vec to fixed-size arrays
  var
    zkproof: ZKSNARK
    proofRoot, shareX, shareY: MerkleNode
    externalNullifier: ExternalNullifier
    nullifier: Nullifier

  # Copy proof bytes (128 bytes)
  if ffi2Proof.proof.len >= 128:
    copyMem(addr zkproof[0], ffi2Proof.proof.data, 128)
  else:
    freeVec(rootVec)
    freeVec(extNullVec)
    freeVec(shareXVec)
    freeVec(shareYVec)
    freeVec(nullifierVec)
    return err("Proof data too short")

  # Copy serialized CFr fields (32 bytes each)
  if rootVec.len >= 32:
    copyMem(addr proofRoot[0], rootVec.data, 32)
  if extNullVec.len >= 32:
    copyMem(addr externalNullifier[0], extNullVec.data, 32)
  if shareXVec.len >= 32:
    copyMem(addr shareX[0], shareXVec.data, 32)
  if shareYVec.len >= 32:
    copyMem(addr shareY[0], shareYVec.data, 32)
  if nullifierVec.len >= 32:
    copyMem(addr nullifier[0], nullifierVec.data, 32)

  # Clean up serialized vectors
  freeVec(rootVec)
  freeVec(extNullVec)
  freeVec(shareXVec)
  freeVec(shareYVec)
  freeVec(nullifierVec)

  # Create the RateLimitProof object
  let output = RateLimitProof(
    proof: zkproof,
    merkleRoot: proofRoot,
    externalNullifier: externalNullifier,
    epoch: epoch,
    rlnIdentifier: rlnIdentifier,
    shareX: shareX,
    shareY: shareY,
    nullifier: nullifier,
  )

  info "Proof generated successfully", proof = output

  waku_rln_remaining_proofs_per_epoch.dec()
  waku_rln_total_generated_proofs.inc()
  return ok(output)

method verifyProof*(
    g: OnchainGroupManager, input: seq[byte], proof: RateLimitProof
): GroupManagerResult[bool] {.gcsafe, raises: [].} =
  ## -- Verifies an RLN rate-limit proof against the set of valid Merkle roots using FFI2 --

  # Compute external nullifier using poseidon
  let extNullifierBytes = poseidon(@[@(proof.epoch), @(proof.rlnIdentifier)]).valueOr:
    return err("Failed to compute external nullifier: " & error)

  # Convert external nullifier to CFr
  var extNullifierVec = newVec(@extNullifierBytes)
  var externalNullifierCFr: CFr
  if not ffi_hash_to_field_le(addr extNullifierVec, addr externalNullifierCFr):
    freeVec(extNullifierVec)
    return err("Failed to convert external nullifier to field element")
  freeVec(extNullifierVec)

  # Convert proof root to CFr
  var rootBytes: seq[byte]
  for b in proof.merkleRoot:
    rootBytes.add(b)
  var rootVec = newVec(rootBytes)
  var rootCFr: CFr
  if not ffi_hash_to_field_le(addr rootVec, addr rootCFr):
    freeVec(rootVec)
    return err("Failed to convert proof root to field element")
  freeVec(rootVec)

  # Convert share_x to CFr
  var shareXBytes: seq[byte]
  for b in proof.shareX:
    shareXBytes.add(b)
  var shareXVec = newVec(shareXBytes)
  var shareXCFr: CFr
  if not ffi_hash_to_field_le(addr shareXVec, addr shareXCFr):
    freeVec(shareXVec)
    return err("Failed to convert share_x to field element")
  freeVec(shareXVec)

  # Convert share_y to CFr
  var shareYBytes: seq[byte]
  for b in proof.shareY:
    shareYBytes.add(b)
  var shareYVec = newVec(shareYBytes)
  var shareYCFr: CFr
  if not ffi_hash_to_field_le(addr shareYVec, addr shareYCFr):
    freeVec(shareYVec)
    return err("Failed to convert share_y to field element")
  freeVec(shareYVec)

  # Convert nullifier to CFr
  var nullifierBytes: seq[byte]
  for b in proof.nullifier:
    nullifierBytes.add(b)
  var nullifierVec = newVec(nullifierBytes)
  var nullifierCFr: CFr
  if not ffi_hash_to_field_le(addr nullifierVec, addr nullifierCFr):
    freeVec(nullifierVec)
    return err("Failed to convert nullifier to field element")
  freeVec(nullifierVec)

  # Convert proof bytes to Vec
  var proofBytes: seq[byte]
  for b in proof.proof:
    proofBytes.add(b)

  # Build ffi_RLNProof structure
  var ffi2Proof = ffi_RLNProof(
    proof: newVec(proofBytes),
    root: rootCFr,
    external_nullifier: externalNullifierCFr,
    share_x: shareXCFr,
    share_y: shareYCFr,
    nullifier: nullifierCFr,
  )

  # Prepare signal (input data)
  var signalVec = newVec(input)

  # Convert valid roots to CFr
  var rootsCFr: seq[CFr]
  for validRoot in g.validRoots.items():
    var validRootBytes: seq[byte]
    for b in validRoot:
      validRootBytes.add(b)
    var validRootVec = newVec(validRootBytes)
    var cfr: CFr
    if not ffi_hash_to_field_le(addr validRootVec, addr cfr):
      freeVec(validRootVec)
      freeVec(ffi2Proof.proof)
      freeVec(signalVec)
      return err("Failed to convert valid root to field element")
    rootsCFr.add(cfr)
    freeVec(validRootVec)

  var rootsVec = newVec(rootsCFr)

  # Verify proof using FFI2 API
  var isValid: bool
  let success = ffi_verify_rln_proof(
    g.rlnInstance, unsafeAddr ffi2Proof, addr signalVec, addr rootsVec, addr isValid
  )

  # Clean up allocated memory
  freeVec(ffi2Proof.proof)
  freeVec(signalVec)
  freeVec(rootsVec)

  if not success:
    return err("Proof verification call failed")

  if isValid:
    info "Proof verified successfully"

  return ok(isValid)

method onRegister*(g: OnchainGroupManager, cb: OnRegisterCallback) {.gcsafe.} =
  g.registerCb = some(cb)

method onWithdraw*(g: OnchainGroupManager, cb: OnWithdrawCallback) {.gcsafe.} =
  g.withdrawCb = some(cb)

proc establishConnection(
    g: OnchainGroupManager
): Future[GroupManagerResult[Web3]] {.async.} =
  var ethRpc: Web3

  g.retryWrapper(ethRpc, "Failed to connect to the Ethereum client"):
    var innerEthRpc: Web3
    var connected = false
    for clientUrl in g.ethClientUrls:
      ## We give a chance to the user to provide multiple clients
      ## and we try to connect to each of them
      try:
        innerEthRpc = await newWeb3(clientUrl)
        connected = true
        break
      except CatchableError:
        error "failed connect Eth client", error = getCurrentExceptionMsg()

    if not connected:
      raise newException(CatchableError, "all failed")

    innerEthRpc

  return ok(ethRpc)

method init*(g: OnchainGroupManager): Future[GroupManagerResult[void]] {.async.} =
  # check if the Ethereum client is reachable
  let ethRpc: Web3 = (await establishConnection(g)).valueOr:
    return err("failed to connect to Ethereum clients: " & $error)

  var fetchedChainId: UInt256
  g.retryWrapper(fetchedChainId, "Failed to get the chain id"):
    await ethRpc.provider.eth_chainId()

  # Set the chain id
  if g.chainId == 0:
    warn "Chain ID not set in config, using RPC Provider's Chain ID",
      providerChainId = fetchedChainId

  if g.chainId != 0 and g.chainId != fetchedChainId:
    return err(
      "The RPC Provided a Chain ID which is different than the provided Chain ID: provided = " &
        $g.chainId & ", actual = " & $fetchedChainId
    )

  g.chainId = fetchedChainId

  if g.ethPrivateKey.isSome():
    let pk = g.ethPrivateKey.get()
    let parsedPk = keys.PrivateKey.fromHex(pk).valueOr:
      return err("failed to parse the private key" & ": " & $error)
    ethRpc.privateKey = Opt.some(parsedPk)
    ethRpc.defaultAccount =
      ethRpc.privateKey.get().toPublicKey().toCanonicalAddress().Address

  let contractAddress = web3.fromHex(web3.Address, g.ethContractAddress)
  let wakuRlnContract = ethRpc.contractSender(WakuRlnContract, contractAddress)

  g.ethRpc = some(ethRpc)
  g.wakuRlnContract = some(wakuRlnContract)

  if g.keystorePath.isSome() and g.keystorePassword.isSome():
    if not fileExists(g.keystorePath.get()):
      error "File provided as keystore path does not exist", path = g.keystorePath.get()
      return err("File provided as keystore path does not exist")

    var keystoreQuery = KeystoreMembership(
      membershipContract:
        MembershipContract(chainId: $g.chainId, address: g.ethContractAddress)
    )
    if g.membershipIndex.isSome():
      keystoreQuery.treeIndex = MembershipIndex(g.membershipIndex.get())
    waku_rln_membership_credentials_import_duration_seconds.nanosecondTime:
      let keystoreCred = getMembershipCredentials(
        path = g.keystorePath.get(),
        password = g.keystorePassword.get(),
        query = keystoreQuery,
        appInfo = RLNAppInfo,
      ).valueOr:
        return err("failed to get the keystore credentials: " & $error)

    g.membershipIndex = some(keystoreCred.treeIndex)
    g.userMessageLimit = some(keystoreCred.userMessageLimit)
    # now we check on the contract if the commitment actually has a membership
    let idCommitmentBytes = keystoreCred.identityCredential.idCommitment
    let idCommitmentUInt256 = keystoreCred.identityCredential.idCommitment.toUInt256()
    let idCommitmentHex = idCommitmentBytes.inHex()
    info "Keystore idCommitment in bytes", idCommitmentBytes = idCommitmentBytes
    info "Keystore idCommitment in UInt256 ", idCommitmentUInt256 = idCommitmentUInt256
    info "Keystore idCommitment in hex ", idCommitmentHex = idCommitmentHex
    let idCommitment = keystoreCred.identityCredential.idCommitment
    let membershipExists = (await g.fetchMembershipStatus(idCommitment)).valueOr:
      return err("the commitment does not have a membership: " & error)
    info "membershipExists", membershipExists = membershipExists

    g.idCredentials = some(keystoreCred.identityCredential)

  let maxMembershipRateLimitRes = await g.fetchMaxMembershipRateLimit()
  let maxMembershipRateLimit = maxMembershipRateLimitRes.valueOr:
    return err("failed to fetch max membership rate limit: " & error)

  g.rlnRelayMaxMessageLimit = cast[uint64](maxMembershipRateLimit)

  proc onDisconnect() {.async.} =
    error "Ethereum client disconnected"

    var newEthRpc: Web3 = (await g.establishConnection()).valueOr:
      g.onFatalErrorAction("failed to connect to Ethereum clients onDisconnect")
      return

    newEthRpc.ondisconnect = ethRpc.ondisconnect
    g.ethRpc = some(newEthRpc)

  ethRpc.ondisconnect = proc() =
    asyncSpawn onDisconnect()

  g.initialized = true
  return ok()

method stop*(g: OnchainGroupManager): Future[void] {.async, gcsafe.} =
  if g.ethRpc.isSome():
    g.ethRpc.get().ondisconnect = nil
    await g.ethRpc.get().close()

  g.initialized = false

method isReady*(g: OnchainGroupManager): Future[bool] {.async.} =
  initializedGuard(g)

  if g.ethRpc.isNone():
    return false

  if g.wakuRlnContract.isNone():
    return false

  return true
