{.used.}

import
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/bufferstream,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  eth/keys
import
  ../../waku/v2/protocol/waku_swap/waku_swap


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

  test "Cheque Encode/Decode":
    let
      amount = 1'u32
      date = 9000'u32
      beneficiary = @[byte 0, 1, 2]
      cheque = Cheque(beneficiary: beneficiary, amount: amount, date: date)
      pb = cheque.encode()

    let decodedCheque = Cheque.init(pb.buffer)

    check:
      decodedCheque.isErr == false
      decodedCheque.get() == cheque
