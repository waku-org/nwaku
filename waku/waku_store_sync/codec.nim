{.push raises: [].}

import std/sequtils, stew/leb128

import ../common/protobuf, ../waku_core/message, ../waku_core/time, ./common

const
  HashLen = 32
  VarIntLen = 9

proc encode*(value: WakuMessageAndTopic): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, value.pubsub)
  pb.write3(2, value.message.encode())

  return pb

proc deltaEncode*(itemSet: ItemSet): seq[byte] =
  # 1 byte for resolved bool and 32 bytes hash plus 9 bytes varint per elements 
  let capacity = 1 + (itemSet.elements.len * (VarIntLen + HashLen))

  var
    output = newSeqOfCap[byte](capacity)
    lastTime = Timestamp(0)
    buf = Leb128Buf[uint64]()

  for id in itemSet.elements:
    let timeDiff = uint64(id.time) - uint64(lastTime)
    lastTime = id.time

    # encode timestamp
    buf = timediff.toBytes(Leb128)
    output &= @buf

    output &= id.hash

  output &= byte(itemSet.reconciled)

  return output

proc deltaEncode*(value: SyncPayload): seq[byte] =
  if value.ranges.len == 0:
    return @[0]

  var
    output = newSeqOfCap[byte](1000)
    buf = Leb128Buf[uint64]()
    lastTimestamp: Timestamp
    lastHash: Fingerprint
    i = 0
    j = 0

  # the first range is implicit but must be explicit when encoded
  let (bound, _) = value.ranges[0]

  lastTimestamp = bound.a.time
  lastHash = bound.a.hash

  # encode first timestamp
  buf = uint64(lastTimestamp).toBytes(Leb128)
  output &= @buf

  # implicit first hash is always 0 and range type is always skip

  for (bound, rangeType) in value.ranges:
    let timeDiff = uint64(bound.b.time) - uint64(lastTimestamp)
    lastTimestamp = bound.b.time

    # encode timestamp
    buf = timeDiff.toBytes(Leb128)
    output &= @buf

    if timeDiff == 0:
      var sameBytes = 0
      for (byte1, byte2) in zip(lastHash, bound.b.hash):
        sameBytes.inc()

        if byte1 != byte2:
          break

      # encode number of same bytes
      output &= byte(sameBytes)

      # encode hash bytes
      output &= bound.b.hash[0 ..< sameBytes]

    # encode rangeType
    output &= byte(rangeType)

    case rangeType
    of RangeType.Skip:
      continue
    of RangeType.Fingerprint:
      let fingerprint = value.fingerprints[i]
      i.inc()

      output &= fingerprint
    of RangeType.ItemSet:
      let itemSet = value.itemSets[j]
      j.inc()

      # encode how many elements are in the set
      buf = uint64(itemSet.elements.len).toBytes(Leb128)
      output &= @buf

      let encodedSet = itemSet.deltaEncode()

      output &= encodedSet

    continue

  return output

proc deltaDecode*(itemSet: var ItemSet, buffer: seq[byte], setLength: int): int =
  var
    lastTime = Timestamp(0)
    val = 0.uint64
    len = 0.int8
    idx = 0

  while itemSet.elements.len < setLength:
    var slice = buffer[idx ..< idx + VarIntLen]
    (val, len) = uint64.fromBytes(slice, Leb128)
    idx += len

    let time = lastTime + Timestamp(val)
    lastTime = time

    slice = buffer[idx ..< idx + HashLen]
    idx += HashLen
    var hash = EmptyWakuMessageHash
    for i, bytes in slice:
      hash[i] = bytes

    let id = SyncID(time: time, hash: hash)

    itemSet.elements.add(id)

  itemSet.reconciled = bool(buffer[idx])
  idx += 1

  return idx

proc deltaDecode*(T: type SyncPayload, buffer: seq[byte]): T =
  if buffer.len == 1:
    return SyncPayload()

  var
    payload = SyncPayload()
    lastTime = Timestamp(0)
    val = 0.uint64
    len = 0.int8
    idx = 0
    slice = buffer[idx ..< idx + VarIntLen]

  # first timestamp
  (val, len) = uint64.fromBytes(slice, Leb128)
  idx += len
  lastTime = Timestamp(val)

  # implicit first hash is always 0 
  # implicit first range mode is alway skip

  while idx < buffer.len - 1:
    let lowerRangeBound = SyncID(time: lastTime, hash: EmptyWakuMessageHash)

    # decode timestamp diff
    let min = min(idx + VarIntLen, buffer.len)
    slice = buffer[idx ..< min]
    (val, len) = uint64.fromBytes(slice, Leb128)
    idx += len
    let timeDiff = Timestamp(val)

    var hash = EmptyWakuMessageHash
    if timeDiff == 0:
      # decode number of same bytes
      let sameBytes = int(buffer[idx])
      idx += 1

      # decode same bytes
      slice = buffer[idx ..< idx + sameBytes]
      idx += sameBytes
      for i, bytes in slice:
        hash[i] = bytes

    let thisTime = lastTime + timeDiff
    lastTime = thisTime

    let upperRangeBound = SyncID(time: thisTime, hash: hash)

    let bounds = lowerRangeBound .. upperRangeBound

    # decode range type
    let rangeType = RangeType(buffer[idx])
    idx += 1

    payload.ranges.add((bounds, rangeType))

    if rangeType == RangeType.Fingerprint:
      # decode fingerprint
      slice = buffer[idx ..< idx + HashLen]
      idx += HashLen
      var fingerprint = EmptyFingerprint
      for i, bytes in slice:
        fingerprint[i] = bytes

      payload.fingerprints.add(fingerprint)
    elif rangeType == RangeType.ItemSet:
      # decode item set length
      let min = min(idx + VarIntLen, buffer.len)
      slice = buffer[idx ..< min]
      (val, len) = uint64.fromBytes(slice, Leb128)
      idx += len
      let itemSetLength = int(val)

      # decode item set
      var itemSet = ItemSet()
      slice = buffer[idx ..< buffer.len]
      let count = deltaDecode(itemSet, slice, itemSetLength)
      idx += count

      payload.itemSets.add(itemSet)

  return payload

proc decode*(T: type WakuMessageAndTopic, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)

  var pubsub: string
  discard ?pb.getField(1, pubsub)

  var proto: ProtoBuffer
  discard ?pb.getField(2, proto)

  let message = ?WakuMessage.decode(proto.buffer)

  return ok(WakuMessageAndTopic(pubsub: pubsub, message: message))
