{.used.}

import
  std/[options, strscans],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  web3

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
    txid_proof
  ]


# a random confirmed txis (Sepolia)
const TxHashExisting* = TxHash.fromHex(
  "0xc1be5f442d3688a8d3e4b5980a73f15e4351358e0f16e2fdd99c2517c9cf6270"
  )
const TxHashNonExisting* = TxHash.fromHex(
  "0x0000000000000000000000000000000000000000000000000000000000000000"
  )

const EthClient = "https://sepolia.infura.io/v3/470c2e9a16f24057aee6660081729fb9"

proc newTestDummyProtocolNode*(
  switch: Switch, 
  handler: DummyHandler,
  ethClient: string
  ): Future[DummyProtocol] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    dummyProtocol = DummyProtocol.new(peerManager, handler, ethClient)

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
    server = await newTestDummyProtocolNode(serverSwitch, handler, EthClient)

    # setting up a client
    clientSwitch = newTestSwitch()
    let peerManager = PeerManager.new(clientSwitch)
    client = WakuDummyClient.new(peerManager)

    await allFutures(serverSwitch.start(), clientSwitch.start())
    
    clientPeerId = clientSwitch.peerInfo.peerId
    serverRemotePeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "incentivization PoC: dummy protocol with a valid txid eligibility proof":
    let request = genDummyRequestWithTxIdEligibilityProof(@(TxHashExisting.bytes()))
    let response = await client.sendRequest(request, serverRemotePeerInfo)
    check:
      response.isOk()
  
  asyncTest "incentivization PoC: dummy protocol client with an invalid txid eligibility proof":
    let request = genDummyRequestWithTxIdEligibilityProof(@(TxHashNonExisting.bytes()))
    let response = await client.sendRequest(request, serverRemotePeerInfo)
    check:
      response.isErr()
