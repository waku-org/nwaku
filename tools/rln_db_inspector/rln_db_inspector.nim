when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronicles, sequtils, results

import waku/[waku_rln_relay/rln, waku_rln_relay/conversion_utils]

logScope:
  topics = "rln_db_inspector"

type InspectRlnDbConf* = object
  treePath*: string

proc doInspectRlnDb*(conf: InspectRlnDbConf) =
  # 1. load configuration
  trace "configuration", conf = $conf

  # 2. initialize rlnInstance
  let rlnInstance = createRLNInstance(d = 20).valueOr:
    error "failure while creating RLN instance", error
    quit(1)

  # 3. get metadata
  let metadataOpt = rlnInstance.getMetadata().valueOr:
    error "failure while getting RLN metadata", error
    quit(1)

  if metadataOpt.isNone():
    error "RLN metadata does not exist"
    quit(1)
  let metadata = metadataOpt.get()

  info "RLN metadata",
    lastProcessedBlock = metadata.lastProcessedBlock,
    chainId = metadata.chainId,
    contractAddress = metadata.contractAddress,
    validRoots = metadata.validRoots.mapIt(it.inHex())

  quit(0)
