{.push raises: [].}

import std/[options], chronos, stew/[byteutils]

import ../waku_core

const
  DefaultSyncInterval*: Duration = 5.minutes
  DefaultSyncRange*: Duration = 1.hours
  RetryDelay*: Duration = 30.seconds
  SyncReconciliationCodec* = "/vac/waku/reconciliation/1.0"
  SyncTransferCodec* = "/vac/waku/transfer/1.0"
  DefaultGossipSubJitter*: Duration = 20.seconds

type
  Fingerprint* = array[32, byte]

  ID* = object
    time*: Timestamp
    fingerprint*: Fingerprint

  ItemSet* = object
    elements*: seq[ID]
    reconciled*: bool

  RangeType* = enum
    skipRange = 0
    fingerprintRange = 1
    itemSetRange = 2

  SyncPayload* = object
    ranges*: seq[(Slice[ID], RangeType)]
    fingerprints*: seq[Fingerprint]
    itemSets*: seq[ItemSet]

  WakuMessagePayload* = object
    pubsub*: string
    message*: WakuMessage

const EmptyFingerprint*: Fingerprint = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0,
]

const FullFingerprint*: Fingerprint = [
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
]

proc high*(T: type ID): T =
  return ID(time: Timestamp(high(int64)), fingerprint: FullFingerprint)

proc low*(T: type ID): T =
  return ID(time: Timestamp(low(int64)), fingerprint: EmptyFingerprint)

proc `$`*(value: ID): string =
  return '(' & $value.time & ", " & $value.fingerprint & ')'

proc cmp(x, y: Fingerprint): int =
  if x < y:
    return -1
  elif x == y:
    return 0

  return 1

proc cmp*(x, y: ID): int =
  if x.time == y.time:
    return cmp(x.fingerprint, y.fingerprint)

  if x.time < y.time:
    return -1

  return 1

proc `<`*(x, y: ID): bool =
  cmp(x, y) == -1

proc `>`*(x, y: ID): bool =
  cmp(x, y) == 1
