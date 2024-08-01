{.push raises: [].}

import std/options, stew/arrayops
import ../common/protobuf, ../waku_core, ./common

proc encode*(req: SyncPayload): ProtoBuffer =
  var pb = initProtoBuffer()

  if req.syncRange.isSome():
    pb.write3(31, req.syncRange.get()[0])
    pb.write3(32, req.syncRange.get()[1])

  if req.frameSize.isSome():
    pb.write3(33, req.frameSize.get())

  if req.negentropy.len > 0:
    pb.write3(1, req.negentropy)

  if req.hashes.len > 0:
    for hash in req.hashes:
      pb.write3(20, hash)

  return pb

proc decode*(T: type SyncPayload, buffer: seq[byte]): ProtobufResult[T] =
  var req = SyncPayload()
  let pb = initProtoBuffer(buffer)

  var rangeStart: uint64
  var rangeEnd: uint64
  if ?pb.getField(31, rangeStart) and ?pb.getField(32, rangeEnd):
    req.syncRange = some((rangeStart, rangeEnd))
  else:
    req.syncRange = none((uint64, uint64))

  var frame: uint64
  if ?pb.getField(33, frame):
    req.frameSize = some(frame)
  else:
    req.frameSize = none(uint64)

  var negentropy: seq[byte]
  if ?pb.getField(1, negentropy):
    req.negentropy = negentropy
  else:
    req.negentropy = @[]

  var buffer: seq[seq[byte]]
  if not ?pb.getRepeatedField(20, buffer):
    req.hashes = @[]
  else:
    req.hashes = newSeqOfCap[WakuMessageHash](buffer.len)
    for buf in buffer:
      let msg: WakuMessageHash = fromBytes(buf)
      req.hashes.add(msg)

  return ok(req)
