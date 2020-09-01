{.used.}

import
  std/[unittest, options, sets],
  chronos, chronicles,
  utils,
  ../../waku/protocol/v2/waku_filter, ../test_helpers

procSuite "Waku Filter":

  test "encoding and decoding FilterRPC":
    let rpc = FilterRPC(filters: @[ContentFilter(topics: @["foo", "bar"])])

    let buf = rpc.encode()

    let decode = FilterRPC.init(buf.buffer)

    check:
      decode.isErr == false
      decode.value == rpc
