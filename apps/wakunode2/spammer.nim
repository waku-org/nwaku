when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronos,
  chronicles,
  confutils,
  confutils/defs,
  confutils/std/net,
  confutils/toml/defs as confTomlDefs,
  confutils/toml/std/net as confTomlNet,
  stew/[byteutils, results],
  std/times,
  libp2p/protocols/pubsub/gossipsub

import
  ../../waku/factory/waku,
  ../../waku/waku_core,
  ../../waku/node/waku_node,
  ../../waku/common/confutils/envvar/defs as confEnvvarDefs,
  ../../waku/common/confutils/envvar/std/net as confEnvvarNet

type SpammerConfig* = object
  enable* {.desc: "Enable spammer", defaultValue: false, name: "spammer".}: bool
  msgRate* {.
    desc: "Number of messages published per second",
    defaultValue: 10,
    name: "spammer-msg-rate"
  .}: uint64

proc runSpammer*(
    waku: Waku, contentTopic: ContentTopic = "/spammer/0/test/plain"
) {.async.} =
  try:
    var conf = SpammerConfig.load()

    if not conf.enable:
      return
    var ephemeral = true
    while true:
      var message = WakuMessage(
        payload: toBytes("Hello World!"),
        contentTopic: contentTopic,
        #      meta: metaBytes,
        version: 2,
        timestamp: getNanosecondTime(getTime().toUnixFloat()),
        ephemeral: ephemeral,
      )

      let pubRes = await waku.node.publish(none(PubsubTopic), message)
      if pubRes.isErr():
        error "failed to publish", msg = pubRes.error
      #echo await (waku.node.isReady())
      await sleepAsync(80)
  except CatchableError:
    error "Failed to load config", err = err(getCurrentExceptionMsg())
    quit(QuitFailure)
