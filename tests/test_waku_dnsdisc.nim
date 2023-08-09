{.used.}

import
  std/[sequtils, tables],
  stew/shims/net,
  stew/[base32, results],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  eth/keys,
  discovery/dnsdisc/builder
import
  ../../waku/node/peer_manager,
  ../../waku/waku_node,
  ../../waku/waku_dnsdisc,
  ./testlib/common,
  ./testlib/wakucore,
  ./testlib/wakunode

suite "Waku DNS Discovery":
  asyncTest "Waku DNS Discovery end-to-end":
    ## Tests integrated DNS discovery, from building
    ## the tree to connecting to discovered nodes

    # Create nodes and ENR. These will be added to the discoverable list
    let
      bindIp = ValidIpAddress.init("0.0.0.0")
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, bindIp, Port(63500))
      enr1 = node1.enr
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, bindIp, Port(63502))
      enr2 = node2.enr
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, bindIp, Port(63503))
      enr3 = node3.enr

    await node1.mountRelay()
    await node2.mountRelay()
    await node3.mountRelay()
    await allFutures([node1.start(), node2.start(), node3.start()])

    # Build and sign tree
    var tree = buildTree(1,                   # Seq no
                         @[enr1, enr2, enr3], # ENR entries
                         @[]).get()           # No link entries

    let treeKeys = keys.KeyPair.random(rng[])

    # Sign tree
    check:
      tree.signTree(treeKeys.seckey()).isOk()

    # Create TXT records at domain
    let
      domain = "testnodes.aq"
      zoneTxts = tree.buildTXT(domain).get()
      username = Base32.encode(treeKeys.pubkey().toRawCompressed())
      location = LinkPrefix & username & "@" & domain # See EIP-1459: https://eips.ethereum.org/EIPS/eip-1459

    # Create a resolver for the domain

    proc resolver(domain: string): Future[string] {.async, gcsafe.} =
      return zoneTxts[domain]

    # Create Waku DNS discovery client on a new Waku v2 node using the resolver

    let
      nodeKey4 = generateSecp256k1Key()
      node4 = newTestWakuNode(nodeKey4, bindIp, Port(63504))

    await node4.mountRelay()
    await node4.start()

    var wakuDnsDisc = WakuDnsDiscovery.init(location, resolver).get()

    let res = wakuDnsDisc.findPeers()

    check:
      # We have discovered all three nodes
      res.isOk()
      res[].len == 3
      res[].mapIt(it.peerId).contains(node1.switch.peerInfo.peerId)
      res[].mapIt(it.peerId).contains(node2.switch.peerInfo.peerId)
      res[].mapIt(it.peerId).contains(node3.switch.peerInfo.peerId)

    # Connect to discovered nodes
    await node4.connectToNodes(res[])

    check:
      # We have successfully connected to all discovered nodes
      node4.peerManager.peerStore.peers().anyIt(it.peerId == node1.switch.peerInfo.peerId)
      node4.peerManager.peerStore.connectedness(node1.switch.peerInfo.peerId) == Connected
      node4.peerManager.peerStore.peers().anyIt(it.peerId == node2.switch.peerInfo.peerId)
      node4.peerManager.peerStore.connectedness(node2.switch.peerInfo.peerId) == Connected
      node4.peerManager.peerStore.peers().anyIt(it.peerId == node3.switch.peerInfo.peerId)
      node4.peerManager.peerStore.connectedness(node3.switch.peerInfo.peerId) == Connected

    await allFutures([node1.stop(), node2.stop(), node3.stop(), node4.stop()])
