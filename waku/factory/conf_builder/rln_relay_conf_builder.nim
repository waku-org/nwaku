import chronicles, std/options, results
import ../waku_conf

logScope:
  topics = "waku conf builder rln relay"

##############################
## RLN Relay Config Builder ##
##############################
type RlnRelayConfBuilder* = object
  enabled*: Option[bool]

  chainId*: Option[uint]
  ethClientAddress*: Option[string]
  ethContractAddress*: Option[string]
  credIndex*: Option[uint]
  credPassword*: Option[string]
  credPath*: Option[string]
  dynamic*: Option[bool]
  epochSizeSec*: Option[uint64]
  userMessageLimit*: Option[uint64]
  treePath*: Option[string]

proc init*(T: type RlnRelayConfBuilder): RlnRelayConfBuilder =
  RlnRelayConfBuilder()

proc withEnabled*(b: var RlnRelayConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withChainId*(b: var RlnRelayConfBuilder, chainId: uint) =
  b.chainId = some(chainId)

proc withCredIndex*(b: var RlnRelayConfBuilder, credIndex: uint) =
  b.credIndex = some(credIndex)

proc withCredPassword*(b: var RlnRelayConfBuilder, credPassword: string) =
  b.credPassword = some(credPassword)

proc withCredPath*(b: var RlnRelayConfBuilder, credPath: string) =
  b.credPath = some(credPath)

proc withDynamic*(b: var RlnRelayConfBuilder, dynamic: bool) =
  b.dynamic = some(dynamic)

proc withEthClientAddress*(b: var RlnRelayConfBuilder, ethClientAddress: string) =
  b.ethClientAddress = some(ethClientAddress)

proc withEthContractAddress*(b: var RlnRelayConfBuilder, ethContractAddress: string) =
  b.ethContractAddress = some(ethContractAddress)

proc withEpochSizeSec*(b: var RlnRelayConfBuilder, epochSizeSec: uint64) =
  b.epochSizeSec = some(epochSizeSec)

proc withUserMessageLimit*(b: var RlnRelayConfBuilder, userMessageLimit: uint64) =
  b.userMessageLimit = some(userMessageLimit)

proc withTreePath*(b: var RlnRelayConfBuilder, treePath: string) =
  b.treePath = some(treePath)

proc build*(b: RlnRelayConfBuilder): Result[Option[RlnRelayConf], string] =
  if not b.enabled.get(false):
    return ok(none(RlnRelayConf))

  if b.chainId.isNone():
    return err("RLN Relay Chain Id is not specified")

  let creds =
    if b.credPath.isSome() and b.credPassword.isSome():
      some(RlnRelayCreds(path: b.credPath.get(), password: b.credPassword.get()))
    elif b.credPath.isSome() and b.credPassword.isNone():
      return err("RLN Relay Credential Password is not specified but path is")
    elif b.credPath.isNone() and b.credPassword.isSome():
      return err("RLN Relay Credential Path is not specified but password is")
    else:
      none(RlnRelayCreds)

  if b.dynamic.isNone():
    return err("rlnRelay.dynamic is not specified")
  if b.ethClientAddress.get("") == "":
    return err("rlnRelay.ethClientAddress is not specified")
  if b.ethContractAddress.get("") == "":
    return err("rlnRelay.ethContractAddress is not specified")
  if b.epochSizeSec.isNone():
    return err("rlnRelay.epochSizeSec is not specified")
  if b.userMessageLimit.isNone():
    return err("rlnRelay.userMessageLimit is not specified")
  if b.treePath.isNone():
    return err("rlnRelay.treePath is not specified")

  return ok(
    some(
      RlnRelayConf(
        chainId: b.chainId.get(),
        credIndex: b.credIndex,
        creds: creds,
        dynamic: b.dynamic.get(),
        ethClientAddress: b.ethClientAddress.get(),
        ethContractAddress: b.ethContractAddress.get(),
        epochSizeSec: b.epochSizeSec.get(),
        userMessageLimit: b.userMessageLimit.get(),
        treePath: b.treePath.get(),
      )
    )
  )
