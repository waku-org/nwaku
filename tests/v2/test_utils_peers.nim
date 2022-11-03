{.used.}

import
  stew/results,
  testutils/unittests,
  libp2p/multiaddress,
  libp2p/peerid,
  libp2p/errors
import
  ../../waku/v2/utils/peers

suite "Utils - Peers":
  
  test "Peer info parses correctly":
    ## Given 
    let address = "/ip4/127.0.0.1/tcp/65002/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      
    ## When
    let remotePeerInfo = parseRemotePeerInfo(address)
    
    ## Then
    check:
      $(remotePeerInfo.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(remotePeerInfo.addrs[0][0].tryGet()) == "/ip4/127.0.0.1"
      $(remotePeerInfo.addrs[0][1].tryGet()) == "/tcp/65002"
    
  test "DNS multiaddrs parsing - dns peer":
    ## Given
    let address = "/dns/localhost/tcp/65012/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let dnsPeer = parseRemotePeerInfo(address)

    ## Then
    check:
      $(dnsPeer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(dnsPeer.addrs[0][0].tryGet()) == "/dns/localhost"
      $(dnsPeer.addrs[0][1].tryGet()) == "/tcp/65012"

  test "DNS multiaddrs parsing - dnsaddr peer":
    ## Given
    let address = "/dnsaddr/localhost/tcp/65022/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
    
    ## When
    let dnsAddrPeer = parseRemotePeerInfo(address)

    ## Then
    check:
      $(dnsAddrPeer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(dnsAddrPeer.addrs[0][0].tryGet()) == "/dnsaddr/localhost"
      $(dnsAddrPeer.addrs[0][1].tryGet()) == "/tcp/65022"

  test "DNS multiaddrs parsing - dns4 peer":
    ## Given
    let address = "/dns4/localhost/tcp/65032/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let dns4Peer = parseRemotePeerInfo(address)

    # Then
    check:
      $(dns4Peer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(dns4Peer.addrs[0][0].tryGet()) == "/dns4/localhost"
      $(dns4Peer.addrs[0][1].tryGet()) == "/tcp/65032"
  
  test "DNS multiaddrs parsing - dns6 peer":
    ## Given
    let address = "/dns6/localhost/tcp/65042/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"

    ## When
    let dns6Peer = parseRemotePeerInfo(address)

    ## Then
    check:
      $(dns6Peer.peerId) == "16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
      $(dns6Peer.addrs[0][0].tryGet()) == "/dns6/localhost"
      $(dns6Peer.addrs[0][1].tryGet()) == "/tcp/65042"

  test "Multiaddr parsing should fail with invalid address":
    ## Given
    let address = "/p2p/$UCH GIBBER!SH"

    ## Then
    expect LPError:
      discard parseRemotePeerInfo(address)

  test "Multiaddr parsing should fail with leading whitespace":
    ## Given
    let address = " /ip4/127.0.0.1/tcp/65062/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
    
    ## Then
    expect LPError:
      discard parseRemotePeerInfo(address)

  test "Multiaddr parsing should fail with trailing whitespace":
    ## Given
    let address = "/ip4/127.0.0.1/tcp/65072/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc "
    
    ## Then
    expect LPError:
      discard parseRemotePeerInfo(address)

  test "Multiaddress parsing should fail with invalid IP address":
    ## Given
    let address = "/ip4/127.0.0.0.1/tcp/65082/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
    
    ## Then
    expect LPError:
      discard parseRemotePeerInfo(address)

  test "Multiaddress parsing should fail with no peer ID":
    ## Given
    let address = "/ip4/127.0.0.1/tcp/65092"
    
    # Then
    expect LPError:
      discard parseRemotePeerInfo(address)

  test "Multiaddress parsing should fail with unsupported transport":
    ## Given
    let address = "/ip4/127.0.0.1/udp/65102/p2p/16Uuu2HBmAcHvhLqQKwSSbX6BG5JLWUDRcaLVrehUVqpw7fz1hbYc"
    
    ## Then
    expect ValueError:
      discard parseRemotePeerInfo(address)

