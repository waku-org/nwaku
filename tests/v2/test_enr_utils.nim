{.used.}

import
  std/[options,sequtils],
  chronos,
  stew/byteutils,
  testutils/unittests,
  ../../waku/v2/utils/wakuenr,
  ../test_helpers

procSuite "ENR utils":

  asyncTest "Parse multiaddr field":
    let
      reasonable = "0x000A047F0000010601BADD03".hexToSeqByte()
      reasonableDns4 = ("0x002F36286E6F64652D30312E646F2D616D73332E77616B7576322E746" &
                       "573742E737461747573696D2E6E65740601BBDE03003837316E6F64652D" &
                       "30312E61632D636E2D686F6E676B6F6E672D632E77616B7576322E74657" &
                       "3742E737461747573696D2E6E65740601BBDE030029BD03ADADEC040BE0" &
                       "47F9658668B11A504F3155001F231A37F54C4476C07FB4CC139ED7E30304D2DE03").hexToSeqByte()
      tooLong = "0x000B047F0000010601BADD03".hexToSeqByte()
      tooShort = "0x000A047F0000010601BADD0301".hexToSeqByte()
      gibberish = "0x3270ac4e5011123c".hexToSeqByte()
      empty = newSeq[byte]()
    
    ## Note: we expect to fail optimistically, i.e. extract
    ## any addresses we can and ignore other errors.
    ## Worst case scenario is we return an empty `multiaddrs` seq.    
    check:
      # Expected cases
      reasonable.toMultiAddresses().contains(MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[])
      reasonableDns4.toMultiAddresses().contains(MultiAddress.init("/dns4/node-01.do-ams3.wakuv2.test.statusim.net/tcp/443/wss")[])
      # Buffer exceeded
      tooLong.toMultiAddresses().len() == 0
      # Buffer remainder
      tooShort.toMultiAddresses().contains(MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[])
      # Gibberish
      gibberish.toMultiAddresses().len() == 0
      # Empty
      empty.toMultiAddresses().len() == 0

  asyncTest "Init ENR for Waku Usage":
    # Tests RFC31 encoding "happy path"
    let
      enrIp = ValidIpAddress.init("127.0.0.1")
      enrTcpPort, enrUdpPort = Port(61101)
      enrKey = wakuenr.crypto.PrivateKey.random(Secp256k1, rng[])[]
      wakuFlags = initWakuFlags(false, true, false, true)
      multiaddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[],
                     MultiAddress.init("/ip4/127.0.0.1/tcp/443/wss")[]]

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
      decodedFlags = record.get(WAKU_ENR_FIELD, seq[byte])[]
      decodedAddrs = record.get(MULTIADDR_ENR_FIELD, seq[byte])[].toMultiAddresses()
    check:
      decodedFlags == @[wakuFlags.byte]
      decodedAddrs.contains(MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[])
      decodedAddrs.contains(MultiAddress.init("/ip4/127.0.0.1/tcp/443/wss")[])
  
  asyncTest "Strip multiaddr peerId":
    # Tests that peerId is stripped of multiaddrs as per RFC31
    let
      enrIp = ValidIpAddress.init("127.0.0.1")
      enrTcpPort, enrUdpPort = Port(61102)
      enrKey = wakuenr.crypto.PrivateKey.random(Secp256k1, rng[])[]
      multiaddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/443/wss/p2p/16Uiu2HAm4v86W3bmT1BiH6oSPzcsSr31iDQpSN5Qa882BCjjwgrD")[]]

    let
      record = initEnr(enrKey, some(enrIp),
                       some(enrTcpPort), some(enrUdpPort),
                       none(WakuEnrBitfield),
                       multiaddrs)

    # Check Waku ENR fields
    let
      decodedAddrs = record.get(MULTIADDR_ENR_FIELD, seq[byte])[].toMultiAddresses()
    
    check decodedAddrs.contains(MultiAddress.init("/ip4/127.0.0.1/tcp/443/wss")[]) # Peer Id has been stripped

  asyncTest "Decode ENR with multiaddrs field":
    let
      # Known values correspond to shared test vectors with other Waku implementations
      knownIp = ValidIpAddress.init("18.223.219.100")
      knownUdpPort = some(9000.int)
      knownTcpPort = none(int)
      knownMultiaddrs = @[MultiAddress.init("/dns4/node-01.do-ams3.wakuv2.test.statusim.net/tcp/443/wss")[],
                          MultiAddress.init("/dns6/node-01.ac-cn-hongkong-c.wakuv2.test.statusim.net/tcp/443/wss")[]]
      knownEnr = "enr:-QEnuEBEAyErHEfhiQxAVQoWowGTCuEF9fKZtXSd7H_PymHFhGJA3rGAYDVSH" &
                  "KCyJDGRLBGsloNbS8AZF33IVuefjOO6BIJpZIJ2NIJpcIQS39tkim11bHRpYWRkcn" &
                  "O4lgAvNihub2RlLTAxLmRvLWFtczMud2FrdXYyLnRlc3Quc3RhdHVzaW0ubmV0BgG" &
                  "73gMAODcxbm9kZS0wMS5hYy1jbi1ob25na29uZy1jLndha3V2Mi50ZXN0LnN0YXR1" &
                  "c2ltLm5ldAYBu94DACm9A62t7AQL4Ef5ZYZosRpQTzFVAB8jGjf1TER2wH-0zBOe1" &
                  "-MDBNLeA4lzZWNwMjU2azGhAzfsxbxyCkgCqq8WwYsVWH7YkpMLnU2Bw5xJSimxKav-g3VkcIIjKA"

    var enrRecord: Record
    check:
      enrRecord.fromURI(knownEnr)
    
    let typedRecord = enrRecord.toTypedRecord.get()

     # Check EIP-778 ENR fields
    check:
      ipv4(typedRecord.ip.get()) == knownIp
      typedRecord.tcp == knownTcpPort
      typedRecord.udp == knownUdpPort
    
    # Check Waku ENR fields
    let
      decodedAddrs = enrRecord.get(MULTIADDR_ENR_FIELD, seq[byte])[].toMultiAddresses()
    
    for knownMultiaddr in knownMultiaddrs:
      check decodedAddrs.contains(knownMultiaddr)

  asyncTest "Supports specific capabilities encoded in the ENR":
    let
      enrIp = ValidIpAddress.init("127.0.0.1")
      enrTcpPort, enrUdpPort = Port(60000)
      enrKey = wakuenr.crypto.PrivateKey.random(Secp256k1, rng[])[]
      multiaddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[]]
      
      # TODO: Refactor initEnr, provide enums as inputs initEnr(capabilites=[Store,Filter])
      # TODO: safer than a util function and directly using the bits
      # test all flag combinations 2^4 = 16 (b0000-b1111)
      records = toSeq(0b0000_0000'u8..0b0000_1111'u8)
                        .mapIt(initEnr(enrKey,
                                       some(enrIp),
                                       some(enrTcpPort),
                                       some(enrUdpPort),
                                       some(uint8(it)),
                                       multiaddrs))

      # same order:         lightpush | filter| store | relay
      expectedCapabilities = @[[false, false, false, false],
                               [false, false, false, true],
                               [false, false, true, false],
                               [false, false, true, true],
                               [false, true, false, false],
                               [false, true, false, true],
                               [false, true, true, false],
                               [false, true, true, true],
                               [true, false, false, false],
                               [true, false, false, true],
                               [true, false, true, false],
                               [true, false, true, true],
                               [true, true, false, false],
                               [true, true, false, true],
                               [true, true, true, false],
                               [true, true, true, true]]
    
    for i, record in records:
      for j, capability in @[Lightpush, Filter, Store, Relay]:
        check expectedCapabilities[i][j] == record.supportsCapability(capability)

  asyncTest "Get all supported capabilities encoded in the ENR":
    let
      enrIp = ValidIpAddress.init("127.0.0.1")
      enrTcpPort, enrUdpPort = Port(60000)
      enrKey = wakuenr.crypto.PrivateKey.random(Secp256k1, rng[])[]
      multiaddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/442/ws")[]]
      
      records = @[0b0000_0000'u8,
                  0b0000_1111'u8,
                  0b0000_1001'u8,
                  0b0000_1110'u8,
                  0b0000_1000'u8,]
                  .mapIt(initEnr(enrKey,
                                 some(enrIp),
                                 some(enrTcpPort),
                                 some(enrUdpPort),
                                 some(uint8(it)),
                                 multiaddrs))

      # expected capabilities, ordered LSB to MSB
      expectedCapabilities: seq[seq[Capabilities]] = @[
      #[0b0000_0000]#          @[],
      #[0b0000_1111]#          @[Relay, Store, Filter, Lightpush],
      #[0b0000_1001]#          @[Relay, Lightpush],
      #[0b0000_1110]#          @[Store, Filter, Lightpush],
      #[0b0000_1000]#          @[Lightpush]]

    for i, actualExpetedTuple in zip(records, expectedCapabilities):
      check actualExpetedTuple[0].getCapabilities() == actualExpetedTuple[1]

  asyncTest "Get supported capabilities of a non waku node":
    
    # non waku enr, i.e. Ethereum one 
    let nonWakuEnr = "enr:-KG4QOtcP9X1FbIMOe17QNMKqDxCpm14jcX5tiOE4_TyMrFqbmhPZHK_ZPG2G"&
    "xb1GE2xdtodOfx9-cgvNtxnRyHEmC0ghGV0aDKQ9aX9QgAAAAD__________4JpZIJ2NIJpcIQDE8KdiXNl"&
    "Y3AyNTZrMaEDhpehBDbZjM_L9ek699Y7vhUJ-eAdMyQW_Fil522Y0fODdGNwgiMog3VkcIIjKA"
    
    var nonWakuEnrRecord: Record
    
    check:
      nonWakuEnrRecord.fromURI(nonWakuEnr)

    # check that it doesn't support any capability and it doesnt't break
    check:
      nonWakuEnrRecord.getCapabilities() == []
      nonWakuEnrRecord.supportsCapability(Relay) == false
      nonWakuEnrRecord.supportsCapability(Store) == false
      nonWakuEnrRecord.supportsCapability(Filter) == false
      nonWakuEnrRecord.supportsCapability(Lightpush) == false