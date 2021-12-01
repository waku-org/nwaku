{.used.}

import
  testutils/unittests,
  std/options,
  stew/byteutils,
  chronos,
  ../../waku/v2/utils/wakuenr,
  ../test_helpers

procSuite "ENR utils":

  asyncTest "Parse multiaddr field":
    let
      reasonable = "0x000A047F0000010601BADD03".hexToSeqByte()
      tooLong = "0x000B047F0000010601BADD03".hexToSeqByte()
      tooShort = "0x000A047F0000010601BADD0301".hexToSeqByte()
      gibberish = "0x3270ac4e5011123c".hexToSeqByte()
      empty = newSeq[byte]()
    
    ## Note: we expect to fail optimistically, i.e. extract
    ## any addresses we can and ignore other errors.
    ## Worst case scenario is we return an empty `multiaddrs` seq.    
    check:
      # Expected case
      reasonable.toMultiAddresses().contains(MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[])
      # Buffer exceeded
      tooLong.toMultiAddresses().len() == 0
      # Buffer remainder
      tooShort.toMultiAddresses().contains(MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[])
      # Gibberish
      gibberish.toMultiAddresses().len() == 0
      # Empty
      empty.toMultiAddresses().len() == 0

  asyncTest "Init ENR for Waku Usage":
    let
      enrIp = ValidIpAddress.init("127.0.0.1")
      enrTcpPort, enrUdpPort = Port(60000)
      enrKey = PrivateKey.random(Secp256k1, rng[])[]
      wakuFlags = initWakuFlags(false, true, false, true)
      multiaddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[], MultiAddress.init("/ip4/127.0.0.1/tcp/443/wss/p2p/16Uiu2HAm4v86W3bmT1BiH6oSPzcsSr31iDQpSN5Qa882BCjjwgrD")[]]

    let
      record = initEnr(enrKey, some(enrIp),
                       some(enrTcpPort), some(enrUdpPort),
                       some(wakuFlags),
                       multiaddrs)
      typedRecord = record.toTypedRecord.get()
    
    # Check EIP-778 ENR fields
    check:
      @(typedRecord.secp256k1.get()) == enrKey.getPublicKey()[].getRawBytes()[]
      ipv4(typedRecord.ip.get()) == enrIp
      Port(typedRecord.tcp.get()) == enrTcpPort
      Port(typedRecord.udp.get()) == enrUdpPort
    
    # Check Waku ENR fields
    let
      decodedFlags = record.get(WAKU_ENR_FIELD, seq[byte])
      decodedAddrs = record.get(MULTIADDR_ENR_FIELD, seq[byte]).toMultiAddresses()
    check:
      decodedFlags == @[wakuFlags.byte]
      decodedAddrs.contains(MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[])
      decodedAddrs.contains(MultiAddress.init("/ip4/127.0.0.1/tcp/443/wss")[]) # Peer Id has been stripped
