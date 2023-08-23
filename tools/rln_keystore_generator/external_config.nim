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

    rlnRelayCredPassword* {.
      desc: "Password for encrypting RLN credentials",
      defaultValue: "",
      name: "rln-relay-cred-password" }: string

    rlnRelayEthPrivateKey* {.
      desc: "Private key for broadcasting transactions",
      defaultValue: "",
      name: "rln-relay-eth-private-key" }: string

proc loadConfig*(T: type RlnKeystoreGeneratorConf): Result[T, string] =
  try:
    let conf = RlnKeystoreGeneratorConf.load()
    if conf.rlnRelayCredPath == "":
      return err("--rln-relay-cred-path must be set")
    if conf.rlnRelayEthContractAddress == "":
      return err("--rln-relay-eth-contract-address must be set")
    if conf.rlnRelayCredPassword == "":
      return err("--rln-relay-cred-password must be set")
    if conf.rlnRelayEthPrivateKey == "":
      return err("--rln-relay-eth-private-key must be set")
    ok(conf)
  except CatchableError:
    err(getCurrentExceptionMsg())
  except Exception:
    err(getCurrentExceptionMsg())
