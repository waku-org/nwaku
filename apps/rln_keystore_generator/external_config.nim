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
  RlnKeystoreGeneratorConf* = object
    configFile* {.
      desc: "Loads configuration from a TOML file (cmd-line parameters take precedence)",
      name: "config-file" }: Option[InputFile]

    execute* {.
      desc: "Runs the registration function on-chain. By default, a dry-run will occur",
      defaultValue: false,
      name: "execute" .}: bool

    ## General node config
    rlnRelayCredPath* {.
      desc: "The path for peristing rln-relay credential",
      defaultValue: "",
      name: "rln-relay-cred-path" }: string

    rlnRelayEthClientAddress* {.
      desc: "WebSocket address of an Ethereum testnet client e.g., ws://localhost:8540/",
      defaultValue: "ws://localhost:8540/",
      name: "rln-relay-eth-client-address" }: string

    rlnRelayEthContractAddress* {.
      desc: "Address of membership contract on an Ethereum testnet",
      defaultValue: "",
      name: "rln-relay-eth-contract-address" }: string

    rlnRelayCredentialsPassword* {.
      desc: "Password for encrypting RLN credentials",
      defaultValue: "",
      name: "rln-relay-cred-password" }: string

proc loadConfig*(T: type RlnKeystoreGeneratorConf): Result[T, string] =
  try:
    let conf = RlnKeystoreGeneratorConf.load()
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())
  except Exception:
    err(getCurrentExceptionMsg())
