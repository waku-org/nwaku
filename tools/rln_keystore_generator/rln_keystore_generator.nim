when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronicles, results, std/[tempfiles, sequtils]

import
  waku/[
    waku_keystore,
    waku_rln_relay/rln,
    waku_rln_relay/conversion_utils,
    waku_rln_relay/group_manager/on_chain,
  ]

logScope:
  topics = "rln_keystore_generator"

type RlnKeystoreGeneratorConf* = object
  execute*: bool
  ethContractAddress*: string
  ethClientAddress*: string
  chainId*: uint
  credPath*: string
  credPassword*: string
  userMessageLimit*: uint64
  ethPrivateKey*: string

proc doRlnKeystoreGenerator*(conf: RlnKeystoreGeneratorConf) =
  # 1. load configuration
  trace "configuration", conf = $conf

  # 2. initialize rlnInstance
  let rlnInstanceRes = createRLNInstance(
    d = 20, tree_path = genTempPath("rln_tree", "rln_keystore_generator")
  )
  if rlnInstanceRes.isErr():
    error "failure while creating RLN instance", error = rlnInstanceRes.error
    quit(1)

  let rlnInstance = rlnInstanceRes.get()

  # 3. generate credentials
  let credentialRes = rlnInstance.membershipKeyGen()
  if credentialRes.isErr():
    error "failure while generating credentials", error = credentialRes.error
    quit(1)

  let credential = credentialRes.get()
  debug "credentials",
    idTrapdoor = credential.idTrapdoor.inHex(),
    idNullifier = credential.idNullifier.inHex(),
    idSecretHash = credential.idSecretHash.inHex(),
    idCommitment = credential.idCommitment.inHex()

  if not conf.execute:
    info "not executing, exiting"
    quit(0)

  var onFatalErrorAction = proc(msg: string) {.gcsafe, closure.} =
    ## Action to be taken when an internal error occurs during the node run.
    ## e.g. the connection with the database is lost and not recovered.
    error "Unrecoverable error occurred", error = msg
    quit(QuitFailure)

  # 4. initialize OnchainGroupManager
  let groupManager = OnchainGroupManager(
    ethClientUrl: conf.rlnRelayEthClientAddress.mapIt(string(it)),
    chainId: conf.chainId,
    ethContractAddress: conf.ethContractAddress,
    rlnInstance: rlnInstance,
    keystorePath: none(string),
    keystorePassword: none(string),
    ethPrivateKey: some(conf.ethPrivateKey),
    onFatalErrorAction: onFatalErrorAction,
  )
  try:
    (waitFor groupManager.init()).isOkOr:
      error "failure while initializing OnchainGroupManager", error = $error
      quit(1)
  # handling the exception is required since waitFor raises an exception
  except Exception, CatchableError:
    error "failure while initializing OnchainGroupManager",
      error = getCurrentExceptionMsg()
    quit(1)

  # 5. register on-chain
  try:
    waitFor groupManager.register(credential, conf.userMessageLimit)
  except Exception, CatchableError:
    error "failure while registering credentials on-chain",
      error = getCurrentExceptionMsg()
    quit(1)

  debug "Transaction hash", txHash = groupManager.registrationTxHash.get()

  info "Your membership has been registered on-chain.",
    chainId = $groupManager.chainId,
    contractAddress = conf.ethContractAddress,
    membershipIndex = groupManager.membershipIndex.get()
  info "Your user message limit is", userMessageLimit = conf.userMessageLimit

  # 6. write to keystore
  let keystoreCred = KeystoreMembership(
    membershipContract: MembershipContract(
      chainId: $groupManager.chainId, address: conf.ethContractAddress
    ),
    treeIndex: groupManager.membershipIndex.get(),
    identityCredential: credential,
    userMessageLimit: conf.userMessageLimit,
  )

  let persistRes =
    addMembershipCredentials(conf.credPath, keystoreCred, conf.credPassword, RLNAppInfo)
  if persistRes.isErr():
    error "failed to persist credentials", error = persistRes.error
    quit(1)

  info "credentials persisted", path = conf.credPath

  try:
    waitFor groupManager.stop()
  except CatchableError:
    error "failure while stopping OnchainGroupManager", error = getCurrentExceptionMsg()
    quit(0) # 0 because we already registered on-chain
  quit(0)
