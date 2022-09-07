{.used.}

import
  std/options,
  testutils/unittests, 
  chronicles,
  chronos, 
  libp2p/switch,
  libp2p/crypto/crypto
import
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_lightpush,
  ../test_helpers


const 
  DefaultPubsubTopic = "/waku/2/default-waku/proto"
  DefaultContentTopic = ContentTopic("/waku/2/default-content/proto")


# TODO: Extend lightpush protocol test coverage
procSuite "Waku Lightpush":

  asyncTest "handle light push request success":
    # TODO: Move here the test case at test_wakunode: light push request success
    discard

  asyncTest "handle light push request fail":
    let
      key = PrivateKey.random(ECDSA, rng[]).get()
      listenSwitch = newStandardSwitch(some(key))
    await listenSwitch.start()

    let dialSwitch = newStandardSwitch()
    await dialSwitch.start()


    proc requestHandler(requestId: string, msg: PushRequest) {.gcsafe, closure.} =
      # TODO Success return here
      debug "handle push req"
      check:
        1 == 0

    # FIXME Unclear how we want to use subscriptions, if at all
    let
      peerManager = PeerManager.new(dialSwitch)
      rng = crypto.newRng()
      proto = WakuLightPush.init(peerManager, rng, requestHandler)

    proto.setPeer(listenSwitch.peerInfo.toRemotePeerInfo())
    waitFor proto.start()
    dialSwitch.mount(proto)


    # TODO Can possibly get rid of this if it isn't dynamic
    proc requestHandler2(requestId: string, msg: PushRequest) {.gcsafe, closure.} =
      debug "push request handler"
      # TODO: Also relay message
      # TODO: Here we want to send back response with is_success true
      discard

    let
      peerManager2 = PeerManager.new(listenSwitch)
      rng2 = crypto.newRng() 
      proto2 = WakuLightPush.init(peerManager2, rng2, requestHandler2)
    waitFor proto2.start()
    listenSwitch.mount(proto2)


    ## Given
    let
      msg = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: DefaultContentTopic)
      rpc = PushRequest(message: msg, pubSubTopic: DefaultPubsubTopic)

    ## When
    let res = await proto.request(rpc)

    ## Then
    check res.isOk()
    let response = res.get()
    check:
      not response.isSuccess

    ## Cleanup
    await allFutures(listenSwitch.stop(), dialSwitch.stop())