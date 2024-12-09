{.push raises: [].}

import std/options, chronos

import ../common/enr, ../waku_enr/capabilities, ../waku_enr/sharding

const DiscoverLimit* = 1000
const DefaultRegistrationTTL* = 60.seconds
const DefaultRegistrationInterval* = 10.seconds
const PeersRequestedCount* = 12

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

proc getRelayShards*(enr: enr.Record): Option[RelayShards] =
  let typedRecord = enr.toTyped().valueOr:
    return none(RelayShards)

  return typedRecord.relaySharding()
