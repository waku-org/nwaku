{.push raises: [].}

import 
    std/[options],
    results,
    libp2p/crypto/curve25519,
    nimcrypto/utils as ncrutils

import ../common/enr

const MixKeyEnrField* = "mix-key"

func withMixKey*(builder: var EnrBuilder, mixPrivKey:string) =
  let mixKey = intoCurve25519Key(ncrutils.fromHex(mixPrivKey))
  let mixPubKey = public(mixKey)
  builder.addFieldPair(MixKeyEnrField, getBytes(mixPubKey))

func mixKey*(record: TypedRecord): Option[seq[byte]] =
  let field = record.tryGet(MixKeyEnrField, seq[byte])
  if field.isNone():
    return none(seq[byte])
  return field
