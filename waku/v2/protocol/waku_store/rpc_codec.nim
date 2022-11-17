when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  nimcrypto/hash
import
  ../../../common/protobuf,
  ../waku_message,
  ./common,
  ./rpc


const MaxRpcSize* = MaxPageSize * MaxWakuMessageSize + 64*1024 # We add a 64kB safety buffer for protocol overhead


## Pagination

proc encode*(index: PagingIndexRPC): ProtoBuffer =
  ## Encode an Index object into a ProtoBuffer
  ## returns the resultant ProtoBuffer
  var pb = initProtoBuffer()

  pb.write3(1, index.digest.data)
  pb.write3(2, zint64(index.receiverTime))
  pb.write3(3, zint64(index.senderTime))
  pb.write3(4, index.pubsubTopic)
  pb.finish3()

  pb

proc decode*(T: type PagingIndexRPC, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns an Index object out of buffer
  var rpc = PagingIndexRPC()
  let pb = initProtoBuffer(buffer)

  var data: seq[byte]
  if not ?pb.getField(1, data):
    return err(ProtoError.RequiredFieldMissing)
  else:
    var digest = MessageDigest()
    for count, b in data:
      digest.data[count] = b

    rpc.digest = digest

  var receiverTime: zint64
  if not ?pb.getField(2, receiverTime):
    return err(ProtoError.RequiredFieldMissing)
  else:
    rpc.receiverTime = int64(receiverTime)

  var senderTime: zint64
  if not ?pb.getField(3, senderTime):
    return err(ProtoError.RequiredFieldMissing)
  else:
    rpc.senderTime = int64(senderTime)

  var pubsubTopic: string
  if not ?pb.getField(4, pubsubTopic):
    return err(ProtoError.RequiredFieldMissing)
  else:
    rpc.pubsubTopic = pubsubTopic

  ok(rpc) 


proc encode*(rpc: PagingInfoRPC): ProtoBuffer =
  ## Encodes a PagingInfo object into a ProtoBuffer
  ## returns the resultant ProtoBuffer
  var pb = initProtoBuffer()

  pb.write3(1, rpc.pageSize.map(proc(size: uint64): zint64 = zint64(size)))
  pb.write3(2, rpc.cursor.map(encode))
  pb.write3(3, rpc.direction.map(proc(d: PagingDirectionRPC): uint32 = uint32(ord(d))))
  pb.finish3()

  pb

proc decode*(T: type PagingInfoRPC, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns a PagingInfo object out of buffer
  var rpc = PagingInfoRPC()
  let pb = initProtoBuffer(buffer)

  var pageSize: zint64
  if not ?pb.getField(1, pageSize):
    rpc.pageSize = none(uint64)
  else:
    rpc.pageSize = some(uint64(pageSize))

  var cursorBuffer: seq[byte]
  if not ?pb.getField(2, cursorBuffer):
    rpc.cursor = none(PagingIndexRPC)
  else:
    let cursor = ?PagingIndexRPC.decode(cursorBuffer)
    rpc.cursor = some(cursor)

  var direction: uint32
  if not ?pb.getField(3, direction):
    rpc.direction = none(PagingDirectionRPC)
  else:
    rpc.direction = some(PagingDirectionRPC(direction))

  ok(rpc) 


## Wire protocol

proc encode*(rpc: HistoryContentFilterRPC): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.contentTopic)
  pb.finish3()

  pb

proc decode*(T: type HistoryContentFilterRPC, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var contentTopic: ContentTopic
  if not ?pb.getField(1, contentTopic):
    return err(ProtoError.RequiredFieldMissing)

  ok(HistoryContentFilterRPC(contentTopic: contentTopic))


proc encode*(rpc: HistoryQueryRPC): ProtoBuffer =
  var pb = initProtoBuffer()
  pb.write3(2, rpc.pubsubTopic)
  
  for filter in rpc.contentFilters:
    pb.write3(3, filter.encode())

  pb.write3(4, rpc.pagingInfo.map(encode))
  pb.write3(5, rpc.startTime.map(proc (time: int64): zint64 = zint64(time)))
  pb.write3(6, rpc.endTime.map(proc (time: int64): zint64 = zint64(time)))
  pb.finish3()

  pb

proc decode*(T: type HistoryQueryRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = HistoryQueryRPC()
  let pb = initProtoBuffer(buffer)

  var pubsubTopic: string
  if not ?pb.getField(2, pubsubTopic):
    rpc.pubsubTopic = none(string)
  else:
    rpc.pubsubTopic = some(pubsubTopic)

  var buffs: seq[seq[byte]]
  if not ?pb.getRepeatedField(3, buffs):
    rpc.contentFilters = @[]
  else:
    for pb in buffs:
      let filter = ?HistoryContentFilterRPC.decode(pb)
      rpc.contentFilters.add(filter)

  var pagingInfoBuffer: seq[byte]
  if not ?pb.getField(4, pagingInfoBuffer):
    rpc.pagingInfo = none(PagingInfoRPC)
  else:
    let pagingInfo = ?PagingInfoRPC.decode(pagingInfoBuffer)
    rpc.pagingInfo = some(pagingInfo)

  var startTime: zint64
  if not ?pb.getField(5, startTime):
    rpc.startTime = none(int64)
  else:
    rpc.startTime = some(int64(startTime))

  var endTime: zint64
  if not ?pb.getField(6, endTime):
    rpc.endTime = none(int64)
  else:
    rpc.endTime = some(int64(endTime))

  ok(rpc)


proc encode*(response: HistoryResponseRPC): ProtoBuffer =
  var pb = initProtoBuffer()

  for rpc in response.messages:
    pb.write3(2, rpc.encode())

  pb.write3(3, response.pagingInfo.map(encode))
  pb.write3(4, uint32(ord(response.error)))
  pb.finish3()

  pb

proc decode*(T: type HistoryResponseRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = HistoryResponseRPC()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]
  if ?pb.getRepeatedField(2, messages):
    for pb in messages:
      let message = ?WakuMessage.decode(pb)
      rpc.messages.add(message)
  else:
    rpc.messages = @[]

  var pagingInfoBuffer: seq[byte]
  if ?pb.getField(3, pagingInfoBuffer):
    let pagingInfo = ?PagingInfoRPC.decode(pagingInfoBuffer)
    rpc.pagingInfo = some(pagingInfo)
  else:
    rpc.pagingInfo = none(PagingInfoRPC)

  var error: uint32
  if not ?pb.getField(4, error):
    return err(ProtoError.RequiredFieldMissing)
  else:
    rpc.error = HistoryResponseErrorRPC.parse(error)

  ok(rpc)


proc encode*(rpc: HistoryRPC): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)
  pb.write3(2, rpc.query.map(encode))
  pb.write3(3, rpc.response.map(encode))
  pb.finish3()

  pb

proc decode*(T: type HistoryRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = HistoryRPC()
  let pb = initProtoBuffer(buffer)

  if not ?pb.getField(1, rpc.requestId):
    return err(ProtoError.RequiredFieldMissing)

  var queryBuffer: seq[byte]
  if not ?pb.getField(2, queryBuffer):
    rpc.query = none(HistoryQueryRPC)
  else:
    let query = ?HistoryQueryRPC.decode(queryBuffer)
    rpc.query = some(query)

  var responseBuffer: seq[byte]
  if not ?pb.getField(3, responseBuffer):
    rpc.response = none(HistoryResponseRPC)
  else:
    let response = ?HistoryResponseRPC.decode(responseBuffer)
    rpc.response = some(response)

  ok(rpc)
