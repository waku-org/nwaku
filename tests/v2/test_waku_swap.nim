import
  std/[unittest, options, tables, sets],
  chronos, chronicles,
  ../../waku/protocol/v2/waku_swap,
  ../../waku/node/v2/waku_types,
  ../test_helpers, ./utils

procSuite "Waku SWAP Accounting":
  test "Handshake Encode/Decode":
    let
      beneficiary = @[byte 0, 1, 2]
      handshake = Handshake(beneficiary: beneficiary)
      pb = handshake.encode()

    let decodedHandshake = Handshake.init(pb.buffer)

    check:
      decodedHandshake.isErr == false
      decodedHandshake.get().beneficiary == beneficiary

    # TODO Cheque test
