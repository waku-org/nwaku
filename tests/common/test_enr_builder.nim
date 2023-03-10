{.used.}

import
  std/options ,
  stew/results,
  stew/shims/net,
  testutils/unittests
import
  ../../waku/common/enr,
  ../v2/testlib/waku2


suite "nim-eth ENR - builder":

  test "Non-supported private key (ECDSA)":
    ## Given
    let privateKey = generateEcdsaKey()

    ## Then
    expect Defect:
      discard EnrBuilder.init(privateKey)

  test "Supported private key (Secp256k1)":
    let
      seqNum = 1u64
      privateKey = generateSecp256k1Key()

    let expectedPubKey = privateKey.getPublicKey().get().getRawBytes().get()

    ## When
    var builder = EnrBuilder.init(privateKey, seqNum)
    let enrRes = builder.build()

    ## Then
    check enrRes.isOk()

    let record = enrRes.tryGet().toTypedRecord().get()
    check:
      @(record.secp256k1.get()) == expectedPubKey


suite "nim-eth ENR - builder ext: IP address and TCP/UDP ports":

  test "EIP-778 test vector":
    ## Given
    # Test vector from EIP-778
    # See: https://eips.ethereum.org/EIPS/eip-778#test-vectors
    let expectedEnr = "-IS4QHCYrYZbAKWCBRlAy5zzaDZXJBGkcnh4MHcBFZntXNFrdvJjX04j" &
                      "RzjzCBOonrkTfj499SZuOh8R33Ls8RRcy5wBgmlkgnY0gmlwhH8AAAGJ" &
                      "c2VjcDI1NmsxoQPKY0yuDUmstAHYpMa2_oxVtw0RW_QAdpzBQA8yWM0x" &
                      "OIN1ZHCCdl8"

    let
      seqNum = 1u64
      privateKey = ethSecp256k1Key("b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291")

      enrIpAddr = ValidIpAddress.init("127.0.0.1")
      enrUdpPort = Port(30303)

    ## When
    var builder = EnrBuilder.init(privateKey, seqNum)
    builder.withIpAddressAndPorts(ipAddr=some(enrIpAddr), udpPort=some(enrUdpPort))

    let enrRes = builder.build()

    ## Then
    check enrRes.isOk()

    let record = enrRes.tryGet().toBase64()
    check:
      record == expectedEnr

  test "IPv4 and TCP port":
    let
      seqNum = 1u64
      privateKey = generateSecp256k1Key()

      enrIpAddr = ValidIpAddress.init("127.0.0.1")
      enrTcpPort = Port(30301)

    let expectedPubKey = privateKey.getPublicKey().get().getRawBytes().get()

    ## When
    var builder = EnrBuilder.init(privateKey, seqNum)
    builder.withIpAddressAndPorts(
      ipAddr=some(enrIpAddr),
      tcpPort=some(enrTcpPort),
    )

    let enrRes = builder.build()

    ## Then
    check enrRes.isOk()

    let record = enrRes.tryGet().toTypedRecord().get()
    check:
      @(record.secp256k1.get()) == expectedPubKey
      record.ip == some(enrIpAddr.address_v4)
      record.tcp == some(enrTcpPort.int)
      record.udp == none(int)
      record.ip6 == none(array[0..15, byte])

  test "IPv6 and UDP port":
    let
      seqNum = 1u64
      privateKey = generateSecp256k1Key()

      enrIpAddr = ValidIpAddress.init("::1")
      enrUdpPort = Port(30301)

    let expectedPubKey = privateKey.getPublicKey().get().getRawBytes().get()

    ## When
    var builder = EnrBuilder.init(privateKey, seqNum)
    builder.withIpAddressAndPorts(
      ipAddr=some(enrIpAddr),
      udpPort=some(enrUdpPort),
    )

    let enrRes = builder.build()

    ## Then
    check enrRes.isOk()

    let record = enrRes.tryGet().toTypedRecord().get()
    check:
      @(record.secp256k1.get()) == expectedPubKey
      record.ip == none(array[0..3, byte])
      record.tcp == none(int)
      record.udp == none(int)
      record.ip6 == some(enrIpAddr.address_v6)
      record.tcp6 == none(int)
      record.udp6 == some(enrUdpPort.int)
