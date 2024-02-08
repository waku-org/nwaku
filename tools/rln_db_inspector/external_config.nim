when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results,
  chronos,
  confutils,
  confutils/defs,
  confutils/toml/defs as confTomlDefs,
  confutils/toml/std/net as confTomlNet,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  secp256k1
import
  ../../waku/common/confutils/envvar/defs as confEnvvarDefs,
  ../../waku/common/confutils/envvar/std/net as confEnvvarNet

export
  confTomlDefs,
  confTomlNet,
  confEnvvarDefs,
  confEnvvarNet

type
  RlnDbInspectorConf* = object
    configFile* {.
      desc: "Loads configuration from a TOML file (cmd-line parameters take precedence)",
      name: "config-file" }: Option[InputFile]

    ## General node config
    rlnRelayTreePath* {.
      desc: "The path to the rln-relay tree",
      defaultValue: "",
      name: "rln-relay-tree-path" }: string

    rlnRelayTreePathDiff* {.
      desc: "The path to the rln-relay tree diff",
      defaultValue: "",
      name: "rln-relay-tree-path-diff" }: string


proc loadConfig*(T: type RlnDbInspectorConf): Result[T, string] =
  try:
    let conf = RlnDbInspectorConf.load()
    if conf.rlnRelayTreePath == "":
      return err("--rln-relay-tree-path must be set")
    if conf.rlnRelayTreePathDiff == "":
      return err("--rln-relay-tree-path-diff must be set")
    ok(conf)
  except CatchableError, Exception:
    err(getCurrentExceptionMsg())
