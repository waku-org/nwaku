import chronicles, std/options, results
import libp2p/crypto/crypto, libp2p/crypto/curve25519, mix/curve25519
import ../waku_conf

logScope:
  topics = "waku conf builder mix"

##################################
## Mix Config Builder ##
##################################
type MixConfBuilder* = object
  enabled*: Option[bool]
  mixKey*: Option[string]

proc init*(T: type MixConfBuilder): MixConfBuilder =
  MixConfBuilder()

proc withEnabled*(b: var MixConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withMixKey*(b: var MixConfBuilder, mixKey: string) =
  b.mixKey = some(mixKey)

proc build*(b: MixConfBuilder): Result[Option[MixConf], string] =
  if not b.enabled.get(false):
    return ok(none[MixConf]())
  else:
    if b.mixKey.isSome():
      let mixPrivKey = intoCurve25519Key(ncrutils.fromHex(b.mixKey.get()))
      let mixPubKey = public(mixPrivKey)
      return ok(some(MixConf(mixKey: mixPrivKey, mixPubKey: mixPubKey)))
    else:
      # Generate a new key pair if not provided
      let keyPairResult = generateKeyPair()
      if keyPairResult.isErr:
        return err("Generate key pair error: " & $keyPairResult.error)
      let (mixPrivKey, mixPubKey) = keyPairResult.get()
      return ok(some(MixConf(mixKey: mixPrivKey, mixPubKey: mixPubKey)))
