when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/options, stew/arrayops
import ../common/protobuf, ../waku_core, ./common

proc encode*(req: SyncPayload): ProtoBuffer =
  var pb = initProtoBuffer()

  if req.rangeStart.isSome() and req.rangeEnd.isSome():
    pb.write3(1, req.rangeStart.get())
    pb.write3(2, req.rangeEnd.get())

  if req.frameSize.isSome():
    pb.write3(3, req.frameSize.get())

  if req.negentropy.len > 0:
    pb.write3(4, req.negentropy)

  if req.hashes.len > 0:
    for hash in req.hashes:
      pb.write3(5, hash)

  return pb

proc decode*(T: type SyncPayload, buffer: seq[byte]): ProtobufResult[T] =
  var req = SyncPayload()
  let pb = initProtoBuffer(buffer)

  var start: uint64
  if ?pb.getField(1, start):
    req.rangeStart = some(start)
  else:
    req.rangeStart = none(uint64)

  var `end`: uint64
  if ?pb.getField(2, `end`):
    req.rangeEnd = some(`end`)
  else:
    req.rangeEnd = none(uint64)

  var frame: uint64
  if ?pb.getField(3, frame):
    req.frameSize = some(frame)
  else:
    req.frameSize = none(uint64)

  var negentropy: seq[byte]
  if ?pb.getField(4, negentropy):
    req.negentropy = negentropy
  else:
    req.negentropy = @[]

  var buffer: seq[seq[byte]]
  if not ?pb.getRepeatedField(5, buffer):
    req.hashes = @[]
  else:
    req.hashes = newSeqOfCap[WakuMessageHash](buffer.len)
    for buf in buffer:
      let msg: WakuMessageHash = fromBytes(buf)
      req.hashes.add(msg)

  return ok(req)
