import confutils/defs

import ../../waku/common/logging

type SondaConf* = object ## Log configuration
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
  .}: uint32

{.push warning[ProveInit]: off.}

proc load*(T: type SondaConf): Result[T, string] =
  try:
    let conf = SondaConf.load(version = git_version)
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())

{.pop.}
