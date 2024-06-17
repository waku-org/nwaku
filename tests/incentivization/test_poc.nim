{.used.}

import
  std/[options, strscans],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto

import
  ../../../waku/[
    node/peer_manager,
    waku_core,
  ],
  ../testlib/[assertions, wakucore, testasync, futures, testutils],
  ../../../waku/incentivization/[
    rpc,
    rpc_codec,
    common,
    client,
    protocol,
  ]


proc newTestDummyProtocolNode*(
  switch: Switch, 
  handler: DummyHandler
  ): Future[DummyProtocol] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    dummyProtocol = DummyProtocol.new(peerManager, handler)

  await dummyProtocol.start()
  switch.mount(dummyProtocol)

  return dummyProtocol


suite "Waku Incentivization PoC Dummy Protocol":

  var
    serverSwitch {.threadvar.}: Switch
    serverRemotePeerInfo {.threadvar.}: RemotePeerInfo
    handlerFuture {.threadvar.}: Future[DummyRequest]
    handler {.threadvar.}: DummyHandler
    server {.threadvar.}: DummyProtocol
    clientSwitch {.threadvar.}: Switch
    client {.threadvar.}: WakuDummyClient
    clientPeerId {.threadvar.}: PeerId

  asyncSetup:

    # setting up a server
    serverSwitch = newTestSwitch()
    handlerFuture = newFuture[DummyRequest]()
    handler = proc(
        peer: PeerId, dummyRequest: DummyRequest
    ): Future[DummyResult[void]] {.async.} =
      handlerFuture.complete(dummyRequest)
      return ok()
    server = await newTestDummyProtocolNode(serverSwitch, handler)

    # setting up a client
    clientSwitch = newTestSwitch()
    let peerManager = PeerManager.new(clientSwitch)
    client = WakuDummyClient.new(peerManager)

    await allFutures(serverSwitch.start(), clientSwitch.start())
    
    clientPeerId = clientSwitch.peerInfo.peerId
    serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "incentivization PoC: dummy protocol with a valid eligibility proof":
    let request = genDummyRequestWithEligibilityProof(true)
    let response = await client.sendRequest(request, serverRemotePeerInfo)
    check:
      response.isOk()
  
  asyncTest "incentivization PoC: dummy protocol client with an invalid eligibility proof":
    let request = genDummyRequestWithEligibilityProof(false)
    let response = await client.sendRequest(request, serverRemotePeerInfo)
    check:
      response.isErr()
