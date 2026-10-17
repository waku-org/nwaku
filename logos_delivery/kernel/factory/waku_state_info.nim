## This module is aimed to collect and provide information about the state of the node,
## such as its version, metrics values, etc.
## It has been originally designed to be used by the debug API, which acts as a consumer of
## this information, but any other module can populate the information it needs to be
## accessible through the debug API.

import std/[strutils]
import metrics, eth/p2p/discoveryv5/enr, libp2p/peerid, stew/byteutils
import logos_delivery/kernel/[kernel, net/bound_ports]
import logos_delivery/kernel/factory/waku_conf

type NodeInfoId* {.pure.} = enum
  Version
  Metrics
  MyMultiaddresses
  MyENR
  MyPeerId
  MyBoundPorts
  MyMixPubKey
  MaxMessageSize
  IsRunning

proc getAllPossibleInfoItemIds*(self: Kernel): seq[NodeInfoId] =
  ## Returns all possible options that can be queried to learn about the node's information.
  var ret = newSeq[NodeInfoId](0)
  for item in NodeInfoId:
    ret.add(item)
  return ret

proc getMetrics(): string =
  {.gcsafe.}:
    return defaultRegistry.toText() ## defaultRegistry is {.global.} in metrics module

proc getNodeInfoItem*(self: Kernel, infoItemId: NodeInfoId): string =
  ## Returns the content of the info item with the given id if it exists.
  case infoItemId
  of NodeInfoId.Version:
    return git_version
  of NodeInfoId.Metrics:
    return getMetrics()
  of NodeInfoId.MyMultiaddresses:
    return self.info().listenAddresses.join(",")
  of NodeInfoId.MyENR:
    return self.enr.toURI()
  of NodeInfoId.MyPeerId:
    return $PeerId(self.peerId())
  of NodeInfoId.MyBoundPorts:
    return $self.ports
  of NodeInfoId.MyMixPubKey:
    ## Empty when the mix protocol is not mounted on this node.
    if self.protocols.mix.isNil():
      return ""
    return self.protocols.mix.pubKey.to0xHex()
  of NodeInfoId.MaxMessageSize:
    ## Configured max message size (in bytes) for this node.
    return $self.conf.maxMessageSizeBytes
  of NodeInfoId.IsRunning:
    ## "true" between a successful start and stop, "false" otherwise.
    return $self.started
  else:
    return "unknown info item id"
