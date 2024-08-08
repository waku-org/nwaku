{.push raises: [].}

import chronos

import ../waku_enr/capabilities

const DiscoverLimit* = 1000
const DefaultRegistrationInterval* = 2.hours

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
