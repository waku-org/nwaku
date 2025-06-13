import std/sequtils
import chronos, chronicles, libp2p/nameresolving/dnsresolver
import ../waku_node

type
  OnOnlineStateChange* = proc(online: bool) {.gcsafe, raises: [].}

  OnlineMonitor* = ref object
    onOnlineStateChange: OnOnlineStateChange
    dnsNameServers*: seq[IpAddress]
    onlineStateObservers: seq[OnOnlineStateChange]
    networkConnLoopHandle: Future[void] # node: WakuNode

proc checkInternetConnectivity(
    nameServerIps: seq[IpAddress], timeout = 2.seconds
): Future[bool] {.async.} =
  const DNSCheckDomain = "one.one.one.one"
  let nameServers = nameServerIps.mapIt(initTAddress(it, Port(53)))
  let dnsResolver = DnsResolver.new(nameServers)

  # Resolve domain IP
  let resolved = await dnsResolver.resolveIp(DNSCheckDomain, 0.Port, Domain.AF_UNSPEC)
  if resolved.len > 0:
    return true
  else:
    return false

proc updateOnlineState(self: OnlineMonitor) {.async.} =
  if self.onlineStateObservers.len == 0:
    warn "No online state observers registered, cannot notify about online state change"
    return

  let numConnectedPeers =
    if self.node.isNil():
      0
    else:
      self.node.switch.peerStore.peers().countIt(it.connectedness == Connected)

  let online =
    if numConnectedPeers > 0:
      true
    else:
      await checkInternetConnectivity(self.dnsNameServers)

  for onlineStateObserver in self.onlineStateObservers:
    onlineStateObserver(online)

proc networkConnectivityLoop(self: OnlineMonitor): Future[void] {.async.} =
  ## Checks periodically whether the node is online or not
  ## and triggers any change that depends on the network connectivity state
  while true:
    await sleepAsync(15.seconds)
    await self.updateOnlineState()

proc startOnlineMonitor*(self: OnlineMonitor) =
  self.networkConnLoopHandle = self.networkConnectivityLoop()

proc stopOnlineMonitor*(self: OnlineMonitor) {.async.} =
  if not self.networkConnLoopHandle.isNil():
    await self.networkConnLoopHandle.cancelAndWait()

proc setNodeToOnlineMonitor*(self: OnlineMonitor, node: WakuNode) =
  self.node = node

proc addOnlineStateObserver*(self: OnlineMonitor, observer: OnOnlineStateChange) =
  ## Adds an observer that will be called when the online state changes
  if observer notin self.onlineStateObservers:
    self.onlineStateObservers.add(observer)

proc init*(T: type OnlineMonitor, dnsNameServers: seq[IpAddress]): OnlineMonitor =
  T(dnsNameServers: dnsNameServers, onlineStateObservers: @[])
