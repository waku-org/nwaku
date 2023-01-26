{.used.}

import
  std/[options,sequtils, times],
  chronos,
  libp2p/crypto/crypto,
  libp2p/peerid,
  libp2p/peerstore,
  libp2p/multiaddress,
  testutils/unittests
import
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/peer_manager/waku_peer_store,
  ../../waku/v2/node/waku_node,
  ../test_helpers


suite "Extended nim-libp2p Peer Store":
  # Valid peerId missing the last digit. Useful for creating new peerIds
  # basePeerId & "1"
  # basePeerId & "2"
  let basePeerId = "QmeuZJbXrszW2jdT7GdduSjQskPU3S7vvGWKtKgDfkDvW"

  setup:
    # Setup a nim-libp2p peerstore with some peers
    let peerStore = PeerStore.new(capacity = 50)
    var p1, p2, p3, p4, p5, p6: PeerId

    # create five peers basePeerId + [1-5]
    require p1.init(basePeerId & "1")
    require p2.init(basePeerId & "2")
    require p3.init(basePeerId & "3")
    require p4.init(basePeerId & "4")
    require p5.init(basePeerId & "5")

    # peer6 is not part of the peerstore
    require p6.init(basePeerId & "6")

    # Peer1: Connected
    peerStore[AddressBook][p1] = @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()]
    peerStore[ProtoBook][p1] = @["/vac/waku/relay/2.0.0-beta1", "/vac/waku/store/2.0.0"]
    peerStore[KeyBook][p1] = KeyPair.random(ECDSA, rng[]).tryGet().pubkey
    peerStore[AgentBook][p1] = "nwaku"
    peerStore[ProtoVersionBook][p1] = "protoVersion1"
    peerStore[ConnectionBook][p1] = Connected
    peerStore[DisconnectBook][p1] = 0
    peerStore[SourceBook][p1] = Discv5
    peerStore[DirectionBook][p1] = Inbound
    peerStore[NumberFailedConnBook][p1] = 1
    peerStore[LastFailedConnBook][p1] = Moment.init(1001, Second)

    # Peer2: Connected
    peerStore[AddressBook][p2] = @[MultiAddress.init("/ip4/127.0.0.1/tcp/2").tryGet()]
    peerStore[ProtoBook][p2] = @["/vac/waku/relay/2.0.0", "/vac/waku/store/2.0.0"]
    peerStore[KeyBook][p2] = KeyPair.random(ECDSA, rng[]).tryGet().pubkey
    peerStore[AgentBook][p2] = "nwaku"
    peerStore[ProtoVersionBook][p2] = "protoVersion2"
    peerStore[ConnectionBook][p2] = Connected
    peerStore[DisconnectBook][p2] = 0
    peerStore[SourceBook][p2] = Discv5
    peerStore[DirectionBook][p2] = Inbound
    peerStore[NumberFailedConnBook][p2] = 2
    peerStore[LastFailedConnBook][p2] = Moment.init(1002, Second)

    # Peer3: Connected
    peerStore[AddressBook][p3] = @[MultiAddress.init("/ip4/127.0.0.1/tcp/3").tryGet()]
    peerStore[ProtoBook][p3] = @["/vac/waku/lightpush/2.0.0", "/vac/waku/store/2.0.0-beta1"]
    peerStore[KeyBook][p3] = KeyPair.random(ECDSA, rng[]).tryGet().pubkey
    peerStore[AgentBook][p3] = "gowaku"
    peerStore[ProtoVersionBook][p3] = "protoVersion3"
    peerStore[ConnectionBook][p3] = Connected
    peerStore[DisconnectBook][p3] = 0
    peerStore[SourceBook][p3] = Discv5
    peerStore[DirectionBook][p3] = Inbound
    peerStore[NumberFailedConnBook][p3] = 3
    peerStore[LastFailedConnBook][p3] = Moment.init(1003, Second)

    # Peer4: Added but never connected
    peerStore[AddressBook][p4] = @[MultiAddress.init("/ip4/127.0.0.1/tcp/4").tryGet()]
    # unknown: peerStore[ProtoBook][p4]
    peerStore[KeyBook][p4] = KeyPair.random(ECDSA, rng[]).tryGet().pubkey
    # unknown: peerStore[AgentBook][p4]
    # unknown: peerStore[ProtoVersionBook][p4]
    peerStore[ConnectionBook][p4] = NotConnected
    peerStore[DisconnectBook][p4] = 0
    peerStore[SourceBook][p4] = Discv5
    peerStore[DirectionBook][p4] = Inbound
    peerStore[NumberFailedConnBook][p4] = 4
    peerStore[LastFailedConnBook][p4] = Moment.init(1004, Second)

    # Peer5: Connecteed in the past
    peerStore[AddressBook][p5] = @[MultiAddress.init("/ip4/127.0.0.1/tcp/5").tryGet()]
    peerStore[ProtoBook][p5] = @["/vac/waku/swap/2.0.0", "/vac/waku/store/2.0.0-beta2"]
    peerStore[KeyBook][p5] = KeyPair.random(ECDSA, rng[]).tryGet().pubkey
    peerStore[AgentBook][p5] = "gowaku"
    peerStore[ProtoVersionBook][p5] = "protoVersion5"
    peerStore[ConnectionBook][p5] = CanConnect
    peerStore[DisconnectBook][p5] = 1000
    peerStore[SourceBook][p5] = Discv5
    peerStore[DirectionBook][p5] = Outbound
    peerStore[NumberFailedConnBook][p5] = 5
    peerStore[LastFailedConnBook][p5] = Moment.init(1005, Second)

  test "get() returns the correct StoredInfo for a given PeerId":
    # When
    let storedInfoPeer1 = peerStore.get(p1)
    let storedInfoPeer6 = peerStore.get(p6)

    # Then
    check:
      # regression on nim-libp2p fields
      storedInfoPeer1.peerId == p1
      storedInfoPeer1.addrs == @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()]
      storedInfoPeer1.protos == @["/vac/waku/relay/2.0.0-beta1", "/vac/waku/store/2.0.0"]
      storedInfoPeer1.agent == "nwaku"
      storedInfoPeer1.protoVersion == "protoVersion1"

      # our extended fields
      storedInfoPeer1.connectedness == Connected
      storedInfoPeer1.disconnectTime == 0
      storedInfoPeer1.origin == Discv5
      storedInfoPeer1.numberFailedConn == 1
      storedInfoPeer1.lastFailedConn == Moment.init(1001, Second)

    check:
      # fields are empty, not part of the peerstore
      storedInfoPeer6.peerId == p6
      storedInfoPeer6.addrs.len == 0
      storedInfoPeer6.protos.len == 0
      storedInfoPeer6.agent == default(string)
      storedInfoPeer6.protoVersion == default(string)
      storedInfoPeer6.connectedness == default(Connectedness)
      storedInfoPeer6.disconnectTime == default(int)
      storedInfoPeer6.origin == default(PeerOrigin)
      storedInfoPeer6.numberFailedConn == default(int)
      storedInfoPeer6.lastFailedConn == default(Moment)

  test "peers() returns all StoredInfo of the PeerStore":
    # When
    let allPeers = peerStore.peers()

    # Then
    check:
      allPeers.len == 5
      allPeers.anyIt(it.peerId == p1)
      allPeers.anyIt(it.peerId == p2)
      allPeers.anyIt(it.peerId == p3)
      allPeers.anyIt(it.peerId == p4)
      allPeers.anyIt(it.peerId == p5)

    let p3 = allPeers.filterIt(it.peerId == p3)[0]

    check:
      # regression on nim-libp2p fields
      p3.addrs == @[MultiAddress.init("/ip4/127.0.0.1/tcp/3").tryGet()]
      p3.protos == @["/vac/waku/lightpush/2.0.0", "/vac/waku/store/2.0.0-beta1"]
      p3.agent == "gowaku"
      p3.protoVersion == "protoVersion3"

      # our extended fields
      p3.connectedness == Connected
      p3.disconnectTime == 0
      p3.origin == Discv5
      p3.numberFailedConn == 3
      p3.lastFailedConn == Moment.init(1003, Second)

  test "peers() returns all StoredInfo matching a specific protocol":
    # When
    let storePeers = peerStore.peers("/vac/waku/store/2.0.0")
    let lpPeers = peerStore.peers("/vac/waku/lightpush/2.0.0")

    # Then
    check:
      # Only p1 and p2 support that protocol
      storePeers.len == 2
      storePeers.anyIt(it.peerId == p1)
      storePeers.anyIt(it.peerId == p2)

    check:
      # Only p3 supports that protocol
      lpPeers.len == 1
      lpPeers.anyIt(it.peerId == p3)
      lpPeers[0].protos == @["/vac/waku/lightpush/2.0.0", "/vac/waku/store/2.0.0-beta1"]

  test "peers() returns all StoredInfo matching a given protocolMatcher":
    # When
    let pMatcherStorePeers = peerStore.peers(protocolMatcher("/vac/waku/store/2.0.0"))
    let pMatcherSwapPeers = peerStore.peers(protocolMatcher("/vac/waku/swap/2.0.0"))

    # Then
    check:
      # peers: 1,2,3,5 match /vac/waku/store/2.0.0/xxx
      pMatcherStorePeers.len == 4
      pMatcherStorePeers.anyIt(it.peerId == p1)
      pMatcherStorePeers.anyIt(it.peerId == p2)
      pMatcherStorePeers.anyIt(it.peerId == p3)
      pMatcherStorePeers.anyIt(it.peerId == p5)

    check:
      pMatcherStorePeers.filterIt(it.peerId == p1)[0].protos == @["/vac/waku/relay/2.0.0-beta1", "/vac/waku/store/2.0.0"]
      pMatcherStorePeers.filterIt(it.peerId == p2)[0].protos == @["/vac/waku/relay/2.0.0", "/vac/waku/store/2.0.0"]
      pMatcherStorePeers.filterIt(it.peerId == p3)[0].protos == @["/vac/waku/lightpush/2.0.0", "/vac/waku/store/2.0.0-beta1"]
      pMatcherStorePeers.filterIt(it.peerId == p5)[0].protos == @["/vac/waku/swap/2.0.0", "/vac/waku/store/2.0.0-beta2"]

    check:
      pMatcherSwapPeers.len == 1
      pMatcherSwapPeers.anyIt(it.peerId == p5)
      pMatcherSwapPeers[0].protos == @["/vac/waku/swap/2.0.0", "/vac/waku/store/2.0.0-beta2"]

  test "toRemotePeerInfo() converts a StoredInfo to a RemotePeerInfo":
    # Given
    let storedInfoPeer1 = peerStore.get(p1)

    # When
    let remotePeerInfo1 = storedInfoPeer1.toRemotePeerInfo()

    # Then
    check:
      remotePeerInfo1.peerId == p1
      remotePeerInfo1.addrs == @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()]
      remotePeerInfo1.protocols == @["/vac/waku/relay/2.0.0-beta1", "/vac/waku/store/2.0.0"]

  test "connectedness() returns the connection status of a given PeerId":
    check:
      # peers tracked in the peerstore
      peerStore.connectedness(p1) == Connected
      peerStore.connectedness(p2) == Connected
      peerStore.connectedness(p3) == Connected
      peerStore.connectedness(p4) == NotConnected
      peerStore.connectedness(p5) == CanConnect

      # peer not tracked in the peerstore
      peerStore.connectedness(p6) == NotConnected

  test "hasPeer() returns true if the peer supports a given protocol":
    check:
      peerStore.hasPeer(p1, "/vac/waku/relay/2.0.0-beta1")
      peerStore.hasPeer(p1, "/vac/waku/store/2.0.0")
      not peerStore.hasPeer(p1, "it-does-not-contain-this-protocol")

      peerStore.hasPeer(p2, "/vac/waku/relay/2.0.0")
      peerStore.hasPeer(p2, "/vac/waku/store/2.0.0")

      peerStore.hasPeer(p3, "/vac/waku/lightpush/2.0.0")
      peerStore.hasPeer(p3, "/vac/waku/store/2.0.0-beta1")

      # we have no knowledge of p4 supported protocols
      not peerStore.hasPeer(p4, "/vac/waku/lightpush/2.0.0")

      peerStore.hasPeer(p5, "/vac/waku/swap/2.0.0")
      peerStore.hasPeer(p5, "/vac/waku/store/2.0.0-beta2")
      not peerStore.hasPeer(p5, "another-protocol-not-contained")

      # peer 6 is not in the PeerStore
      not peerStore.hasPeer(p6, "/vac/waku/lightpush/2.0.0")

  test "hasPeers() returns true if any peer in the PeerStore supports a given protocol":
    # Match specific protocols
    check:
      peerStore.hasPeers("/vac/waku/relay/2.0.0-beta1")
      peerStore.hasPeers("/vac/waku/store/2.0.0")
      peerStore.hasPeers("/vac/waku/lightpush/2.0.0")
      not peerStore.hasPeers("/vac/waku/does-not-exist/2.0.0")

    # Match protocolMatcher protocols
    check:
      peerStore.hasPeers(protocolMatcher("/vac/waku/store/2.0.0"))
      not peerStore.hasPeers(protocolMatcher("/vac/waku/does-not-exist/2.0.0"))

  test "getPeersByDirection()":
    # When
    let inPeers = peerStore.getPeersByDirection(Inbound)
    let outPeers = peerStore.getPeersByDirection(Outbound)

    # Then
    check:
      inPeers.len == 4
      outPeers.len == 1

  test "getNotConnectedPeers()":
    # When
    let disconnedtedPeers = peerStore.getNotConnectedPeers()

    # Then
    check:
      disconnedtedPeers.len == 2
      disconnedtedPeers.anyIt(it.peerId == p4)
      disconnedtedPeers.anyIt(it.peerId == p5)
      not disconnedtedPeers.anyIt(it.connectedness == Connected)

  test "del() successfully deletes waku custom books":
    # Given
    let peerStore = PeerStore.new(capacity = 5)
    var p1: PeerId
    require p1.init("QmeuZJbXrszW2jdT7GdduSjQskPU3S7vvGWKtKgDfkDvW" & "1")
    peerStore[AddressBook][p1] = @[MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet()]
    peerStore[ProtoBook][p1] = @["proto"]
    peerStore[KeyBook][p1] = KeyPair.random(ECDSA, rng[]).tryGet().pubkey
    peerStore[AgentBook][p1] = "agent"
    peerStore[ProtoVersionBook][p1] = "version"
    peerStore[LastFailedConnBook][p1] = Moment.init(getTime().toUnix, Second)
    peerStore[NumberFailedConnBook][p1] = 1
    peerStore[ConnectionBook][p1] = Connected
    peerStore[DisconnectBook][p1] = 0
    peerStore[SourceBook][p1] = Discv5
    peerStore[DirectionBook][p1] = Inbound

    # When
    peerStore.del(p1)

    # Then
    check:
      peerStore[AddressBook][p1] == newSeq[MultiAddress](0)
      peerStore[ProtoBook][p1] == newSeq[string](0)
      peerStore[KeyBook][p1] == default(PublicKey)
      peerStore[AgentBook][p1] == ""
      peerStore[ProtoVersionBook][p1] == ""
      peerStore[LastFailedConnBook][p1] == default(Moment)
      peerStore[NumberFailedConnBook][p1] == 0
      peerStore[ConnectionBook][p1] == default(Connectedness)
      peerStore[DisconnectBook][p1] == 0
      peerStore[SourceBook][p1] == default(PeerOrigin)
      peerStore[DirectionBook][p1] == default(PeerDirection)

  asyncTest "canBeConnected() returns correct value":
    let peerStore = PeerStore.new(capacity = 5)
    var p1: PeerId
    require p1.init("QmeuZJbXrszW2jdT7GdduSjQskPU3S7vvGWKtKgDfkDvW" & "1")

    # with InitialBackoffInSec = 1 backoffs are: 1, 2, 4, 8secs.
    let initialBackoffInSec = 1
    let backoffFactor = 2

    # new peer with no errors can be connected
    check:
      peerStore.canBeConnected(p1, initialBackoffInSec, backoffFactor) == true

    # peer with ONE error that just failed
    peerStore[NumberFailedConnBook][p1] = 1
    peerStore[LastFailedConnBook][p1] = Moment.init(getTime().toUnix, Second)
    # we cant connect right now
    check:
      peerStore.canBeConnected(p1, initialBackoffInSec, backoffFactor) == false

    # but we can after the first backoff of 1 seconds
    await sleepAsync(1200)
    check:
      peerStore.canBeConnected(p1, initialBackoffInSec, backoffFactor) == true

    # peer with TWO errors, we can connect until 2 seconds have passed
    peerStore[NumberFailedConnBook][p1] = 2
    peerStore[LastFailedConnBook][p1] = Moment.init(getTime().toUnix, Second)

    # cant be connected after 1 second
    await sleepAsync(1000)
    check:
      peerStore.canBeConnected(p1, initialBackoffInSec, backoffFactor) == false

    # can be connected after 2 seconds
    await sleepAsync(1200)
    check:
      peerStore.canBeConnected(p1, initialBackoffInSec, backoffFactor) == true
