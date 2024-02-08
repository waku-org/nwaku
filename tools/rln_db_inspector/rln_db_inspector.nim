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

  let rlnInstance2 = createRLNInstance(d=20, tree_path = conf.rlnRelayTreePathDiff).valueOr:
    error "failure while creating RLN instance", error
    quit(1)

  # 3. get metadata
  let metadata = rlnInstance.getMetadata().valueOr:
    error "failure while getting RLN metadata", error
    quit(1)

  let metadata2 = rlnInstance2.getMetadata().valueOr:
    error "failure while getting RLN metadata", error
    quit(1)



  info "RLN metadata", lastProcessedBlock = metadata.lastProcessedBlock, 
                       chainId = metadata.chainId,
                       contractAddress = metadata.contractAddress,
                       validRoots = metadata.validRoots.mapIt(it.inHex())

  info "RLN DIFF metadata", lastProcessedBlock = metadata2.lastProcessedBlock, 
                       chainId = metadata2.chainId,
                       contractAddress = metadata2.contractAddress,
                       validRoots = metadata2.validRoots.mapIt(it.inHex())

  info "RUNNING DIFF CHECK"

  var index: uint = 0
  while true:
    let leaf = rlnInstance.getMember(index).valueOr:
      error "failure while getting RLN member", error
      quit(1)
    let leaf2 = rlnInstance2.getMember(index).valueOr:
      error "failure while getting RLN member", error
      quit(1)

    debug "leaf", index = index, leaf = leaf.inHex(), leaf2 = leaf2.inHex()

    if leaf != leaf2:
      error "DIFF FOUND", index = index, leaf = leaf.inHex(), leaf2 = leaf2.inHex()

    # repeat for 0-31 index
    if leaf[0] == 0 and leaf2[0] == 0 and leaf[1] == 0 and leaf2[1] == 0 and 
      leaf[2] == 0 and leaf2[2] == 0 and leaf[3] == 0 and leaf2[3] == 0 and 
      leaf[4] == 0 and leaf2[4] == 0 and leaf[5] == 0 and leaf2[5] == 0 and
      leaf[6] == 0 and leaf2[6] == 0 and leaf[7] == 0 and leaf2[7] == 0 and
      leaf[8] == 0 and leaf2[8] == 0 and leaf[9] == 0 and leaf2[9] == 0 and
      leaf[10] == 0 and leaf2[10] == 0 and leaf[11] == 0 and leaf2[11] == 0 and
      leaf[12] == 0 and leaf2[12] == 0 and leaf[13] == 0 and leaf2[13] == 0 and
      leaf[14] == 0 and leaf2[14] == 0 and leaf[15] == 0 and leaf2[15] == 0 and
      leaf[16] == 0 and leaf2[16] == 0 and leaf[17] == 0 and leaf2[17] == 0 and
      leaf[18] == 0 and leaf2[18] == 0 and leaf[19] == 0 and leaf2[19] == 0 and
      leaf[20] == 0 and leaf2[20] == 0 and leaf[21] == 0 and leaf2[21] == 0 and
      leaf[22] == 0 and leaf2[22] == 0 and leaf[23] == 0 and leaf2[23] == 0 and
      leaf[24] == 0 and leaf2[24] == 0 and leaf[25] == 0 and leaf2[25] == 0 and
      leaf[26] == 0 and leaf2[26] == 0 and leaf[27] == 0 and leaf2[27] == 0 and
      leaf[28] == 0 and leaf2[28] == 0 and leaf[29] == 0 and leaf2[29] == 0 and
      leaf[30] == 0 and leaf2[30] == 0 and leaf[31] == 0 and leaf2[31] == 0:
      info "reached end of RLN tree", index = index
      quit(0)
    
    index += 1

  quit(0)
