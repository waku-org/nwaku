{.used.}

import std/[options, sequtils], stew/results, testutils/unittests
import waku_core, waku_enr, ./testlib/wakucore

suite "Waku ENR -  Capabilities bitfield":
  test "check capabilities support":
    ## Given
    let bitfield: CapabilitiesBitfield = 0b0000_1101u8 # Lightpush, Filter, Relay

    ## Then
    check:
      bitfield.supportsCapability(Capabilities.Relay)
      not bitfield.supportsCapability(Capabilities.Store)
      bitfield.supportsCapability(Capabilities.Filter)
      bitfield.supportsCapability(Capabilities.Lightpush)

  test "bitfield to capabilities list":
    ## Given
    let bitfield = CapabilitiesBitfield.init(
      relay = true, store = false, lightpush = true, filter = true
    )

    ## When
    let caps = bitfield.toCapabilities()

    ## Then
    check:
      caps == @[Capabilities.Relay, Capabilities.Filter, Capabilities.Lightpush]

  test "encode and decode record with capabilities field (EnrBuilder ext)":
    ## Given
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    ## When
    var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
    builder.withWakuCapabilities(Capabilities.Relay, Capabilities.Store)

    let recordRes = builder.build()

    ## Then
    check recordRes.isOk()
    let record = recordRes.tryGet()

    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let bitfieldOpt = typedRecord.value.waku2
    check bitfieldOpt.isSome()

    let bitfield = bitfieldOpt.get()
    check:
      bitfield.toCapabilities() == @[Capabilities.Relay, Capabilities.Store]

  test "cannot decode capabilities from record":
    ## Given
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    let record = EnrBuilder.init(enrPrivKey, enrSeqNum).build().tryGet()

    ## When
    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let bitfieldOpt = typedRecord.value.waku2

    ## Then
    check bitfieldOpt.isNone()

  test "check capabilities on a waku node record":
    ## Given
    let wakuRecord =
      "-Hy4QC73_E3B_FkZhsOakaD4pHe-U--UoGASdG9N0F3SFFUDY_jdQbud8" &
      "EXVyrlOZ5pZ7VYFBDPMRCENwy87Lh74dFIBgmlkgnY0iXNlY3AyNTZrMaECvNt1jIWbWGp" &
      "AWWdlLGYm1E1OjlkQk3ONoxDC5sfw8oOFd2FrdTID"

    ## When
    var record: Record
    require waku_enr.fromBase64(record, wakuRecord)

    ## Then
    let typedRecordRes = record.toTyped()
    require typedRecordRes.isOk()

    let bitfieldOpt = typedRecordRes.value.waku2
    require bitfieldOpt.isSome()

    let bitfield = bitfieldOpt.get()
    check:
      bitfield.supportsCapability(Capabilities.Relay) == true
      bitfield.supportsCapability(Capabilities.Store) == true
      bitfield.supportsCapability(Capabilities.Filter) == false
      bitfield.supportsCapability(Capabilities.Lightpush) == false
      bitfield.toCapabilities() == @[Capabilities.Relay, Capabilities.Store]

  test "check capabilities on a non-waku node record":
    ## Given
    # non waku enr, i.e. Ethereum one
    let nonWakuEnr =
      "enr:-KG4QOtcP9X1FbIMOe17QNMKqDxCpm14jcX5tiOE4_TyMrFqbmhPZHK_ZPG2G" &
      "xb1GE2xdtodOfx9-cgvNtxnRyHEmC0ghGV0aDKQ9aX9QgAAAAD__________4JpZIJ2NIJpcIQDE8KdiXNl" &
      "Y3AyNTZrMaEDhpehBDbZjM_L9ek699Y7vhUJ-eAdMyQW_Fil522Y0fODdGNwgiMog3VkcIIjKA"

    ## When
    var record: Record
    require waku_enr.fromURI(record, nonWakuEnr)

    ## Then
    let typedRecordRes = record.toTyped()
    require typedRecordRes.isOk()

    let bitfieldOpt = typedRecordRes.value.waku2
    check bitfieldOpt.isNone()

    check:
      record.getCapabilities() == []
      record.supportsCapability(Capabilities.Relay) == false
      record.supportsCapability(Capabilities.Store) == false
      record.supportsCapability(Capabilities.Filter) == false
      record.supportsCapability(Capabilities.Lightpush) == false

suite "Waku ENR - Multiaddresses":
  test "decode record with multiaddrs field":
    ## Given
    let enrUri =
      "enr:-QEnuEBEAyErHEfhiQxAVQoWowGTCuEF9fKZtXSd7H_PymHFhGJA3rGAYDVSH" &
      "KCyJDGRLBGsloNbS8AZF33IVuefjOO6BIJpZIJ2NIJpcIQS39tkim11bHRpYWRkcn" &
      "O4lgAvNihub2RlLTAxLmRvLWFtczMud2FrdXYyLnRlc3Quc3RhdHVzaW0ubmV0BgG" &
      "73gMAODcxbm9kZS0wMS5hYy1jbi1ob25na29uZy1jLndha3V2Mi50ZXN0LnN0YXR1" &
      "c2ltLm5ldAYBu94DACm9A62t7AQL4Ef5ZYZosRpQTzFVAB8jGjf1TER2wH-0zBOe1" &
      "-MDBNLeA4lzZWNwMjU2azGhAzfsxbxyCkgCqq8WwYsVWH7YkpMLnU2Bw5xJSimxKa" &
      "v-g3VkcIIjKA"

    var record: Record
    require record.fromURI(enrUri)

    # TODO: get rid of wakuv2 here too. Needt to generate a ne ENR record
    let
      expectedAddr1 = MultiAddress
        .init("/dns4/node-01.do-ams3.wakuv2.test.statusim.net/tcp/443/wss")
        .get()
      expectedAddr2 = MultiAddress
        .init("/dns6/node-01.ac-cn-hongkong-c.wakuv2.test.statusim.net/tcp/443/wss")
        .get()
      expectedAddr3 = MultiAddress
        .init(
          "/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:1234/wss"
        )
        .get()

    ## When
    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let multiaddrsOpt = typedRecord.value.multiaddrs

    ## Then
    check multiaddrsOpt.isSome()

    let multiaddrs = multiaddrsOpt.get()
    check:
      multiaddrs.len == 3
      multiaddrs.contains(expectedAddr1)
      multiaddrs.contains(expectedAddr2)
      multiaddrs.contains(expectedAddr3)

  test "encode and decode record with multiaddrs field (EnrBuilder ext)":
    ## Given
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    let
      addr1 = MultiAddress.init("/ip4/127.0.0.1/tcp/80/ws").get()
      addr2 = MultiAddress.init("/ip4/127.0.0.1/tcp/443/wss").get()

    ## When
    var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
    builder.withMultiaddrs(addr1, addr2)

    let recordRes = builder.build()

    require recordRes.isOk()
    let record = recordRes.tryGet()

    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let multiaddrsOpt = typedRecord.value.multiaddrs

    ## Then
    check multiaddrsOpt.isSome()

    let multiaddrs = multiaddrsOpt.get()
    check:
      multiaddrs.len == 2
      multiaddrs.contains(addr1)
      multiaddrs.contains(addr2)

  test "cannot decode multiaddresses from record":
    ## Given
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    let record = EnrBuilder.init(enrPrivKey, enrSeqNum).build().tryGet()

    ## When
    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let fieldOpt = typedRecord.value.multiaddrs

    ## Then
    check fieldOpt.isNone()

  test "encode and decode record with multiaddresses field - strip peer ID":
    ## Given
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    let
      addr1 = MultiAddress
        .init(
          "/ip4/127.0.0.1/tcp/80/ws/p2p/16Uiu2HAm4v86W3bmT1BiH6oSPzcsSr31iDQpSN5Qa882BCjjwgrD"
        )
        .get()
      addr2 = MultiAddress.init("/ip4/127.0.0.1/tcp/443/wss").get()

    let expectedAddr1 = MultiAddress.init("/ip4/127.0.0.1/tcp/80/ws").get()

    ## When
    var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
    builder.withMultiaddrs(addr1, addr2)

    let recordRes = builder.build()

    require recordRes.isOk()
    let record = recordRes.tryGet()

    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let multiaddrsOpt = typedRecord.value.multiaddrs

    ## Then
    check multiaddrsOpt.isSome()

    let multiaddrs = multiaddrsOpt.get()
    check:
      multiaddrs.contains(expectedAddr1)
      multiaddrs.contains(addr2)

suite "Waku ENR - Relay static sharding":
  test "new relay shards object with single invalid shard id":
    ## Given
    let
      clusterId: uint16 = 22
      shard: uint16 = 1024

    ## When
    let shardsTopics = RelayShards.init(clusterId, shard)

    ## Then
    assert shardsTopics.isErr(), $shardsTopics.get()

  test "new relay shards object with single invalid shard id in list":
    ## Given
    let
      clusterId: uint16 = 22
      shardIds: seq[uint16] = @[1u16, 1u16, 2u16, 3u16, 5u16, 8u16, 1024u16]

    ## When
    let shardsTopics = RelayShards.init(clusterId, shardIds)

    ## Then
    assert shardsTopics.isErr(), $shardsTopics.get()

  test "new relay shards object with single valid shard id":
    ## Given
    let
      clusterId: uint16 = 22
      shardId: uint16 = 1

    let topic = NsPubsubTopic.staticSharding(clusterId, shardId)

    ## When
    let shardsTopics = RelayShards.init(clusterId, shardId).expect("Valid Shards")

    ## Then
    check:
      shardsTopics.clusterId == clusterId
      shardsTopics.shardIds == @[1u16]

    let topics = shardsTopics.topics.mapIt($it)
    check:
      topics == @[$topic]

    check:
      shardsTopics.contains(clusterId, shardId)
      not shardsTopics.contains(clusterId, 33u16)
      not shardsTopics.contains(20u16, 33u16)

      shardsTopics.contains(topic)
      shardsTopics.contains("/waku/2/rs/22/1")

  test "new relay shards object with repeated but valid shard ids":
    ## Given
    let
      clusterId: uint16 = 22
      shardIds: seq[uint16] = @[1u16, 2u16, 2u16, 3u16, 3u16, 3u16]

    ## When
    let shardsTopics = RelayShards.init(clusterId, shardIds).expect("Valid Shards")

    ## Then
    check:
      shardsTopics.clusterId == clusterId
      shardsTopics.shardIds == @[1u16, 2u16, 3u16]

  test "cannot decode relay shards from record if not present":
    ## Given
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    let record = EnrBuilder.init(enrPrivKey, enrSeqNum).build().tryGet()

    ## When
    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let fieldOpt = typedRecord.value.relaySharding

    ## Then
    check fieldOpt.isNone()

  test "encode and decode record with relay shards field (EnrBuilder ext - shardIds list)":
    ## Given
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    let
      clusterId: uint16 = 22
      shardIds: seq[uint16] = @[1u16, 1u16, 2u16, 3u16, 5u16, 8u16]

    let shardsTopics = RelayShards.init(clusterId, shardIds).expect("Valid Shards")

    ## When
    var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
    require builder.withWakuRelaySharding(shardsTopics).isOk()

    let recordRes = builder.build()

    ## Then
    check recordRes.isOk()
    let record = recordRes.tryGet()

    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let shardsOpt = typedRecord.value.relaySharding
    check:
      shardsOpt.isSome()
      shardsOpt.get() == shardsTopics

  test "encode and decode record with relay shards field (EnrBuilder ext - bit vector)":
    ## Given
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    let shardsTopics =
      RelayShards.init(33, toSeq(0u16 ..< 64u16)).expect("Valid Shards")

    var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
    require builder.withWakuRelaySharding(shardsTopics).isOk()

    let recordRes = builder.build()
    require recordRes.isOk()

    let record = recordRes.tryGet()

    ## When
    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let shardsOpt = typedRecord.value.relaySharding

    ## Then
    check:
      shardsOpt.isSome()
      shardsOpt.get() == shardsTopics

  test "decode record with relay shards shard list and bit vector fields":
    ## Given
    let
      enrSeqNum = 1u64
      enrPrivKey = generatesecp256k1key()

    let
      relayShardsIndicesList = RelayShards
        .init(22, @[1u16, 1u16, 2u16, 3u16, 5u16, 8u16])
        .expect("Valid Shards")
      relayShardsBitVector = RelayShards
        .init(33, @[13u16, 24u16, 37u16, 61u16, 98u16, 159u16])
        .expect("Valid Shards")

    var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
    require builder.withWakuRelayShardingIndicesList(relayShardsIndicesList).isOk()
    require builder.withWakuRelayShardingBitVector(relayShardsBitVector).isOk()

    let recordRes = builder.build()
    require recordRes.isOk()

    let record = recordRes.tryGet()

    ## When
    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let shardsOpt = typedRecord.value.relaySharding

    ## Then
    check:
      shardsOpt.isSome()
      shardsOpt.get() == relayShardsIndicesList
