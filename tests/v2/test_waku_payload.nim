{.used.}

import
  testutils/unittests,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/node/waku_payload,
  ../../waku/v2/utils/time

procSuite "Waku Payload":
  let rng = newRng()

  test "Encode/Decode without encryption (version 0)":
    ## This would be the usual way when no encryption is done or when it is done
    ## on the application layer.

    # Encoding
    let
      version = 0'u32
      payload = @[byte 0, 1, 2]
      msg = WakuMessage(payload: payload, version: version)
      pb =  msg.encode()

    # Decoding
    let msgDecoded = WakuMessage.decode(pb.buffer)
    check msgDecoded.isOk()

    let
      keyInfo = KeyInfo(kind:None)
      decoded = decodePayload(msgDecoded.get(), keyInfo)

    check:
      decoded.isOk()
      decoded.get().payload == payload

  test "Encode/Decode without encryption (version 0) with encodePayload":
    ## This is a bit silly and only there for completeness

    # Encoding
    let
      version = 0'u32
      payload = Payload(payload: @[byte 0, 1, 2])
      encodedPayload = payload.encode(version, rng[])

    check encodedPayload.isOk()
    let
      msg = WakuMessage(payload: encodedPayload.get(), version: version)
      pb =  msg.encode()

    # Decoding
    let msgDecoded = WakuMessage.decode(pb.buffer)
    check msgDecoded.isOk()

    let
      keyInfo = KeyInfo(kind:None)
      decoded = decodePayload(msgDecoded.get(), keyInfo)

    check:
      decoded.isOk()
      decoded.get().payload == payload.payload

  test "Encode/Decode with encryption (version 1)":
    # Encoding
    let
      privKey = PrivateKey.random(rng[])
      version = 1'u32
      payload = Payload(payload: @[byte 0, 1, 2],
        dst: some(privKey.toPublicKey()))
      encodedPayload = payload.encode(version, rng[])

    check encodedPayload.isOk()
    let
      msg = WakuMessage(payload: encodedPayload.get(), version: version)
      pb =  msg.encode()

    # Decoding
    let msgDecoded = WakuMessage.decode(pb.buffer)
    check msgDecoded.isOk()

    let
      keyInfo = KeyInfo(kind: Asymmetric, privKey: privKey)
      decoded = decodePayload(msgDecoded.get(), keyInfo)

    check:
      decoded.isOk()
      decoded.get().payload == payload.payload

  test "Encode with unsupported version":
    let
      version = 2'u32
      payload = Payload(payload: @[byte 0, 1, 2])
      encodedPayload = payload.encode(version, rng[])

    check encodedPayload.isErr()

  test "Decode with unsupported version":
    # Encoding
    let
      version = 2'u32
      payload = @[byte 0, 1, 2]
      msg = WakuMessage(payload: payload, version: version)
      pb =  msg.encode()

    # Decoding
    let msgDecoded = WakuMessage.decode(pb.buffer)
    check msgDecoded.isOk()

    let
      keyInfo = KeyInfo(kind:None)
      decoded = decodePayload(msgDecoded.get(), keyInfo)

    check:
      decoded.isErr()

  test "Encode/Decode waku message with timestamp":
    ## Test encoding and decoding of the timestamp field of a WakuMessage

    ## Given
    let
      version = 0'u32
      payload = @[byte 0, 1, 2]
      timestamp = Timestamp(10)
      msg = WakuMessage(payload: payload, version: version, timestamp: timestamp)
      
    ## When
    let pb =  msg.encode()
    let msgDecoded = WakuMessage.decode(pb.buffer)
    
    ## Then
    check:
      msgDecoded.isOk()
    
    let timestampDecoded = msgDecoded.value.timestamp
    check:
      timestampDecoded == timestamp

  test "Encode/Decode waku message without timestamp":
    ## Test the encoding and decoding of a WakuMessage with an empty timestamp field  

    ## Given
    let
      version = 0'u32
      payload = @[byte 0, 1, 2]
      msg = WakuMessage(payload: payload, version: version)
    
    ## When
    let pb =  msg.encode()
    let msgDecoded = WakuMessage.decode(pb.buffer)

    ## Then
    check:
      msgDecoded.isOk()
    
    let timestampDecoded = msgDecoded.value.timestamp
    check:
      timestampDecoded == Timestamp(0)