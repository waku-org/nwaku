{.used.}

import chronos, testutils/unittests, libp2p/builders, libp2p/protocols/rendezvous

import waku/node/waku_switch, ./testlib/common, ./testlib/wakucore

proc newRendezvousClientSwitch(rdv: RendezVous): Switch =
  SwitchBuilder
  .new()
  .withRng(rng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .withRendezVous(rdv)
  .build()

procSuite "Waku Rendezvous":
  asyncTest "Waku Switch uses Rendezvous":
    ## Setup

    let
      wakuClient = RendezVous.new()
      sourceClient = RendezVous.new()
      destClient = RendezVous.new()
      wakuSwitch = newRendezvousClientSwitch(wakuClient) #rendezvous point
      sourceSwitch = newRendezvousClientSwitch(sourceClient) #client
      destSwitch = newRendezvousClientSwitch(destClient) #client

    # Setup client rendezvous
    wakuClient.setup(wakuSwitch)
    sourceClient.setup(sourceSwitch)
    destClient.setup(destSwitch)

    await allFutures(wakuSwitch.start(), sourceSwitch.start(), destSwitch.start())

    # Connect clients to the rendezvous point
    await sourceSwitch.connect(wakuSwitch.peerInfo.peerId, wakuSwitch.peerInfo.addrs)
    await destSwitch.connect(wakuSwitch.peerInfo.peerId, wakuSwitch.peerInfo.addrs)

    let res0 = await sourceClient.request("empty")
    check res0.len == 0

    # Check that source client gets peer info of dest client from rendezvous point
    await sourceClient.advertise("foo")
    let res1 = await destClient.request("foo")
    check:
      res1.len == 1
      res1[0] == sourceSwitch.peerInfo.signedPeerRecord.data

    await allFutures(wakuSwitch.stop(), sourceSwitch.stop(), destSwitch.stop())
