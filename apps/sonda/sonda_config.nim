import confutils/defs, stew/results

import ../../waku/common/logging

type SondaConf* = object
  logLevel* {.
    desc:
      "Sets the log level for process. Supported levels: TRACE, DEBUG, INFO, NOTICE, WARN, ERROR or FATAL",
    defaultValue: logging.LogLevel.DEBUG,
    name: "log-level"
  .}: logging.LogLevel

  logFormat* {.
    desc:
      "Specifies what kind of logs should be written to stdout. Suported formats: TEXT, JSON",
    defaultValue: logging.LogFormat.TEXT,
    name: "log-format"
  .}: logging.LogFormat

  clusterId* {.
    desc:
      "Cluster id that the node is running in. Node in a different cluster id is disconnected.",
    defaultValue: 0,
    name: "cluster-id"
  .}: uint16

  shard* {.
    desc: "Shard where sonda messages are going to be published",
    defaultValue: 0,
    name: "shard"
  .}: uint16

  period* {.
    desc: "Time in seconds between consecutive sonda messages",
    defaultValue: 60,
    name: "period"
  .}: uint32

  storenodes* {.
    desc: "Multiaddresses of store nodes to query",
    defaultValue: @[],
    name: "storenodes"
  .}: seq[string]

proc loadConfig*(T: type SondaConf, version = ""): Result[T, string] =
  try:
    let conf = SondaConf.load(version = version)
    return ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())
