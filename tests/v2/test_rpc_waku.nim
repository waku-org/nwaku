{.used.}

import
  std/[unittest, options, os, strutils],
  stew/shims/net as stewNet,
  json_rpc/[rpcserver, rpcclient],
  libp2p/crypto/crypto,
  ../../waku/node/v2/[waku_types, wakunode2],
  ../../waku/node/v2/rpc/wakurpc,
  ../../waku/protocol/v2/waku_relay,
  ../test_helpers

template sourceDir*: string = currentSourcePath.rsplit(DirSep, 1)[0]
const sigPath = sourceDir / ParDir / ParDir / "waku" / "node" / "v2" / "rpc" / "wakucallsigs.nim"
createRpcSigs(RpcHttpClient, sigPath)

suite "Waku v2 Remote Procedure Calls":
  # WakuNode setup
  let
    rng = crypto.newRng()
    privkey = crypto.PrivateKey.random(Secp256k1, rng[]).tryGet()
    bindIp = ValidIpAddress.init("0.0.0.0")
    extIp = ValidIpAddress.init("127.0.0.1")
    port = Port(9000)
    node = WakuNode.init(privkey, bindIp, port, some(extIp), some(port))

  waitFor node.start()

  waitFor node.mountRelay(@["waku"])

  # RPC server setup
  let
    rpcPort = Port(8545)
    ta = initTAddress(bindIp, rpcPort)
    server = newRpcHttpServer([ta])

  setupWakuRPC(node, server)
  server.start()

  asyncTest "waku_info":
    # RPC client setup
    let client = newRpcHttpClient()
    await client.connect("127.0.0.1", rpcPort)

    check await(client.waku_version()) == WakuRelayCodec
