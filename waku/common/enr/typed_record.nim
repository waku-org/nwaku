{.push raises: [].}

import std/options, results, eth/keys as eth_keys, libp2p/crypto/crypto as libp2p_crypto

import eth/p2p/discoveryv5/enr except TypedRecord, toTypedRecord

## ENR typed record

# Record identity scheme

type RecordId* {.pure.} = enum
  V4

func toRecordId(id: string): EnrResult[RecordId] =
  case id
  of "v4":
    ok(RecordId.V4)
  else:
    err("unknown identity scheme")

func `$`*(id: RecordId): string =
  case id
  of RecordId.V4: "v4"

# Typed record

type TypedRecord* = object
  raw: Record

proc init(T: type TypedRecord, record: Record): T =
  TypedRecord(raw: record)

proc tryGet*(record: TypedRecord, field: string, T: type): Option[T] =
  record.raw.tryGet(field, T)

func toTyped*(record: Record): EnrResult[TypedRecord] =
  let tr = TypedRecord.init(record)

  # Validate record's identity scheme
  let idOpt = tr.tryGet("id", string)
  if idOpt.isNone():
    return err("missing id scheme field")

  discard ?toRecordId(idOpt.get())

  ok(tr)

# Typed record field accessors

func id*(record: TypedRecord): Option[RecordId] =
  let fieldOpt = record.tryGet("id", string)
  if fieldOpt.isNone():
    return none(RecordId)

  let fieldRes = toRecordId(fieldOpt.get())
  if fieldRes.isErr():
    return none(RecordId)

  some(fieldRes.value)

func secp256k1*(record: TypedRecord): Option[array[33, byte]] =
  record.tryGet("secp256k1", array[33, byte])

func ip*(record: TypedRecord): Option[array[4, byte]] =
  record.tryGet("ip", array[4, byte])

func ip6*(record: TypedRecord): Option[array[16, byte]] =
  record.tryGet("ip6", array[16, byte])

func tcp*(record: TypedRecord): Option[uint16] =
  record.tryGet("tcp", uint16)

func tcp6*(record: TypedRecord): Option[uint16] =
  record.tryGet("tcp6", uint16)

func udp*(record: TypedRecord): Option[uint16] =
  record.tryGet("udp", uint16)

func udp6*(record: TypedRecord): Option[uint16] =
  record.tryGet("udp6", uint16)
