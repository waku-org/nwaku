import
  json_rpc/rpcserver, tables, options,
  eth/[common, rlp, keys, p2p],
  #DevP2P impl
  # ../../../protocol/v1/waku_protocol,
  ../../../protocol/v2/waku_protocol,
  nimcrypto/[sysrand, hmac, sha2, pbkdf2],
  ../../v1/rpc/[rpc_types, hexstrings, key_storage],
  ../waku_types

from stew/byteutils import hexToSeqByte, hexToByteArray

# Instead of using rlpx waku_protocol here, lets do mock waku2_protocol
# This should wrap GossipSub, not use EthereumNode here

# In Waku0/1 we use node.protocolState(Waku) a lot to get information
# Also keys to get priate key, etc
# Where is the equivalent in Waku/2?
# TODO: Extend to get access to protocol state and keys
#proc setupWakuRPC*(node: EthereumNode, keys: KeyStorage, rpcsrv: RpcServer) =
proc setupWakuRPC*(wakuProto: WakuProto, rpcsrv: RpcServer) =

  # Seems easy enough, lets try to get this first
  rpcsrv.rpc("waku_version") do() -> string:
     ## Returns string of the current Waku protocol version.
     result = WakuSubCodec

  # XXX Type
  # TODO: Implement symkey etc logic
  rpcsrv.rpc("waku_post") do(message: string) -> bool:
    let data = cast[seq[byte]](message)
    # Assumes someone subscribing on this topic
    #let wakuSub = wakuProto.switch.pubsub
    let wakuSub = cast[WakuSub](wakuProto.switch.pubSub.get())
    # XXX also future return type
    discard wakuSub.publish("foobar", data)
    return true
    #if not result:
    #  raise newException(ValueError, "Message could not be posted")

  # TODO: Dial/Connect
  # XXX: Though wrong layer for that - wait how does this work in devp2p sim?
  # We connect to nodes there, should be very similar here

