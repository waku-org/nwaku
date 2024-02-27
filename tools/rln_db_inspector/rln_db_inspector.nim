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
  let conf = RlnDbInspectorConf.loadConfig().valueOr:
    error "failure while loading the configuration", error
    quit(1)

  trace "configuration", conf = $conf

  # 2. initialize rlnInstance
  let rlnInstance = createRLNInstance(d=20,
                                      tree_path = conf.rlnRelayTreePath).valueOr:
    error "failure while creating RLN instance", error
    quit(1)

  # 3. get metadata
  let metadata = rlnInstance.getMetadata().valueOr:
    error "failure while getting RLN metadata", error
    quit(1)

  info "RLN metadata", lastProcessedBlock = metadata.lastProcessedBlock, 
                       chainId = metadata.chainId,
                       contractAddress = metadata.contractAddress,
                       validRoots = metadata.validRoots.mapIt(it.inHex())

  quit(0)
