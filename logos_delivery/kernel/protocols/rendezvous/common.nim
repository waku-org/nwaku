{.push raises: [].}

import results, chronos

import
  logos_delivery/kernel/common/enr,
  logos_delivery/kernel/enr/capabilities,
  logos_delivery/kernel/enr/sharding

const DiscoverLimit* = 1000
const DefaultRegistrationTTL* = 60.seconds
const DefaultRegistrationInterval* = 10.seconds
const DefaultRequestsInterval* = 1.minutes
const MaxRegistrationInterval* = 5.minutes
const PeersRequestedCount* = 12

proc computeMixNamespace*(clusterId: uint16): string =
  var namespace = "rs/"

  namespace &= $clusterId
  namespace &= "/mix"

  return namespace

proc computeNamespace*(clusterId: uint16, shard: uint16): string =
  var namespace = "rs/"

  namespace &= $clusterId
  namespace &= '/'
  namespace &= $shard

  return namespace

proc computeNamespace*(clusterId: uint16, shard: uint16, cap: Capabilities): string =
  var namespace = "rs/"

  namespace &= $clusterId
  namespace &= '/'
  namespace &= $shard
  namespace &= '/'
  namespace &= $cap

  return namespace

proc getRelayShards*(enr: enr.Record): Opt[RelayShards] =
  let typedRecord = enr.toTyped().valueOr:
    return Opt.none(RelayShards)

  return typedRecord.relaySharding()
