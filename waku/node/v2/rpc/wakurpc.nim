import
  std/options,
  json_rpc/rpcserver,
  nimcrypto/[sysrand, hmac, sha2],
  eth/[common, rlp, keys, p2p],
  ../../../protocol/v2/waku_relay,
  ../waku_types

# Instead of using rlpx waku_protocol here, lets do mock waku2_protocol
# This should wrap GossipSub, not use EthereumNode here

# In Waku0/1 we use node.protocolState(Waku) a lot to get information
# Also keys to get priate key, etc
# Where is the equivalent in Waku/2?
# TODO: Extend to get access to protocol state and keys
#proc setupWakuRPC*(node: EthereumNode, keys: KeyStorage, rpcsrv: RpcServer) =
proc setupWakuRPC*(node: WakuNode, rpcsrv: RpcServer) =

  # Seems easy enough, lets try to get this first
  rpcsrv.rpc("waku_version") do() -> string:
     ## Returns string of the current Waku protocol version.
     result = WakuRelayCodec

  # TODO: Implement symkey etc logic
  rpcsrv.rpc("waku_publish") do(topic: string, payload: seq[byte]) -> bool:
    # XXX Why is casting necessary here but not in Nim node API?
    let wakuRelay = cast[WakuRelay](node.switch.pubSub.get())
    # XXX also future return type
    # TODO: Shouldn't we really be doing WakuNode publish here?
    debug "waku_publish", topic=topic, payload=payload
    discard wakuRelay.publish(topic, payload)
    return true
    #if not result:
    #  raise newException(ValueError, "Message could not be posted")

  rpcsrv.rpc("waku_publish2") do(topic: string, message: WakuMessage) -> bool:
    # XXX also future return type
    debug "waku_publish2", topic=topic, message=message
    discard node.publish(topic, message)
    return true
    #if not result:
    #  raise newException(ValueError, "Message could not be posted")

  # TODO: Handler / Identifier logic
  rpcsrv.rpc("waku_subscribe") do(topic: string) -> bool:
    let wakuRelay = cast[WakuRelay](node.switch.pubSub.get())

    # XXX: Hacky in-line handler
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      info "Hit subscribe handler", topic=topic, data=data

    # TODO: Shouldn't we really be doing WakuNode subscribe here?
    discard wakuRelay.subscribe(topic, handler)
    return true
    #if not result:
    #  raise newException(ValueError, "Message could not be posted")

