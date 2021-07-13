{.used.}

import
  std/[options, tables, sets],
  testutils/unittests, chronos, chronicles,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/multistream,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_lightpush/waku_lightpush,
  ../test_helpers, ./utils

procSuite "Waku Light Push":

  # NOTE See test_wakunode for light push request success
  asyncTest "handle light push request fail":
    const defaultTopic = "/waku/2/default-waku/proto"

    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(key)
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      post = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic)

    var dialSwitch = newStandardSwitch()
    discard await dialSwitch.start()

    var listenSwitch = newStandardSwitch(some(key))
    discard await listenSwitch.start()

    var responseRequestIdFuture = newFuture[string]()
    var completionFut = newFuture[bool]()

    proc handle(requestId: string, msg: PushRequest) {.gcsafe, closure.} =
      # TODO Success return here
      debug "handle push req"
      check:
        1 == 0
      responseRequestIdFuture.complete(requestId)

    # FIXME Unclear how we want to use subscriptions, if at all
    let
      proto = WakuLightPush.init(PeerManager.new(dialSwitch), crypto.newRng(), handle)
      wm = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: contentTopic)
      rpc = PushRequest(pubSubTopic: defaultTopic, message: wm)

    dialSwitch.mount(proto)
    proto.setPeer(listenSwitch.peerInfo)


    # TODO Can possibly get rid of this if it isn't dynamic
    proc requestHandle(requestId: string, msg: PushRequest) {.gcsafe, closure.} =
      debug "push request handler"
      # TODO: Also relay message
      # TODO: Here we want to send back response with is_success true
      discard

    let
      proto2 = WakuLightPush.init(PeerManager.new(listenSwitch), crypto.newRng(), requestHandle)

    listenSwitch.mount(proto2)

    proc handler(response: PushResponse) {.gcsafe, closure.} =
      debug "push response handler, expecting false"
      check:
        response.isSuccess == false
      debug "Additional info", info=response.info
      completionFut.complete(true)

    await proto.request(rpc, handler)
    await sleepAsync(2.seconds)

    check:
      (await completionFut.withTimeout(5.seconds)) == true
