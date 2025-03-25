{.push raises: [].}

import 
    std/[options],
    results,
    libp2p/crypto/curve25519,
    nimcrypto/utils as ncrutils

import ../common/enr

const MixKeyEnrField* = "mix-key"


func withMixKey*(builder: var EnrBuilder, mixPubKey: Curve25519Key) =
  builder.addFieldPair(MixKeyEnrField, getBytes(mixPubKey))

func mixKey*(record: TypedRecord): Option[seq[byte]] =
  let field = record.tryGet(MixKeyEnrField, seq[byte])
  if field.isNone():
    return none(seq[byte])
  return field

func mixKey*(record: Record): Option[seq[byte]] =
  let recordRes = record.toTyped()
  if recordRes.isErr():
    return none(seq[byte])

  let field = recordRes.value.tryGet(MixKeyEnrField, seq[byte])
  if field.isNone():
    return none(seq[byte])
  return field