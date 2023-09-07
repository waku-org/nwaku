when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  sequtils,
  stew/[results]

import
  ../../waku/waku_rln_relay/rln,
  ../../waku/waku_rln_relay/conversion_utils,
  ./external_config

logScope:
  topics = "rln_db_inspector"

when isMainModule:
  {.pop.}
  # 1. load configuration
  let confRes = RlnDbInspectorConf.loadConfig()
  if confRes.isErr():
    error "failure while loading the configuration", error=confRes.error
    quit(1)

  let conf = confRes.get()

  trace "configuration", conf = $conf

  # 2. initialize rlnInstance
  let rlnInstanceRes = createRLNInstance(d=20,
                                         tree_path = conf.rlnRelayTreePath)
  if rlnInstanceRes.isErr():
    error "failure while creating RLN instance", error=rlnInstanceRes.error
    quit(1)

  let rlnInstance = rlnInstanceRes.get()

  # 3. get metadata
  let metadataGetRes = rlnInstance.getMetadata()
  if metadataGetRes.isErr():
    error "failure while getting RLN metadata", error=metadataGetRes.error
    quit(1)

  let metadata = metadataGetRes.get()

  info "RLN metadata", lastProcessedBlock = metadata.lastProcessedBlock, 
                       chainId = metadata.chainId,
                       contractAddress = metadata.contractAddress,
                       validRoots = metadata.validRoots.mapIt(it.inHex())

  quit(0)
