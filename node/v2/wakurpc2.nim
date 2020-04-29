import
  json_rpc/rpcserver, tables, options,
  eth/[common, rlp, keys, p2p],
  #DevP2P impl
  #eth/p2p/rlpx_protocols/waku_protocol,
  waku2_protocol,
  nimcrypto/[sysrand, hmac, sha2, pbkdf2],
  ../../vendor/nimbus/nimbus/rpc/rpc_types,
  ../../vendor/nimbus/nimbus/rpc/hexstrings,
  ../../vendor/nimbus/nimbus/rpc/key_storage

from stew/byteutils import hexToSeqByte, hexToByteArray

# Instead of using rlpx waku_protocol here, lets do mock waku2_protocol
# This should wrap GossipSub, not use EthereumNode here

# Blatant copy of Whisper RPC but for the Waku protocol

# XXX: Wrong, also what is wakuVersionStr?
# We also have rlpx protocol here waku_protocol
proc setupWakuRPC*(node: EthereumNode, keys: KeyStorage, rpcsrv: RpcServer) =

  # Seems easy enough, lets try to get this first
  rpcsrv.rpc("waku_version") do() -> string:
     ## Returns string of the current whisper protocol version.
     # TODO: Should read from waku2_protocol I think
     #result = wakuVersionStr
     result = "2.0.0-alpha0x"

  # TODO: Dial/Connect
  # XXX: Though wrong layer for that - wait how does this work in devp2p sim?
  # We connect to nodes there, should be very similar here

    # We can also do this from nim-waku repo

