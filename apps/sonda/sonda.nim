{.push raises: [].}

import
  std/[options, strutils, os, sequtils, net],
  chronicles,
  chronos,
  metrics,
  libbacktrace,
  system/ansi_c,
  libp2p/crypto/crypto,
  confutils

import ./sonda_config, ../../waku/common/logging, ../../waku/factory/waku

logScope:
  topics = "sonda main"

proc logConfig(conf: SondaConf) =
  info "Configuration: Sonda", conf = $conf

{.pop.}
when isMainModule:
  const versionString = "version / git commit hash: " & waku.git_version

  let confRes = SondaConf.load(version = versionString)
  if confRes.isErr():
    error "failure while loading the configuration", error = confRes.error
    quit(QuitFailure)

  var conf = confRes.get()

  ## Logging setup
  logging.setupLog(conf.logLevel, conf.logFormat)

  info "Running Sonda", version = waku.git_version
  logConfig(conf)
