when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  nimcrypto/hash,
  libp2p/protobuf/minprotobuf,
  libp2p/varint
import
  ../waku_message,
  ../../utils/protobuf,
  ../../utils/time,
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
  var index = PagingIndexRPC()
  let pb = initProtoBuffer(buffer)

  var data: seq[byte]
  discard ?pb.getField(1, data)

  # create digest from data
  index.digest = MessageDigest()
  for count, b in data:
    index.digest.data[count] = b

  # read the timestamp
  var receiverTime: zint64
  discard ?pb.getField(2, receiverTime)
  index.receiverTime = Timestamp(receiverTime)

  # read the timestamp
  var senderTime: zint64
  discard ?pb.getField(3, senderTime)
  index.senderTime = Timestamp(senderTime)

  # read the pubsubTopic
  discard ?pb.getField(4, index.pubsubTopic)

  ok(index) 


proc encode*(pinfo: PagingInfoRPC): ProtoBuffer =
  ## Encodes a PagingInfo object into a ProtoBuffer
  ## returns the resultant ProtoBuffer
  var pb = initProtoBuffer()

  pb.write3(1, pinfo.pageSize)
  pb.write3(2, pinfo.cursor.encode())
  pb.write3(3, uint32(ord(pinfo.direction)))
  pb.finish3()

  pb

proc decode*(T: type PagingInfoRPC, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns a PagingInfo object out of buffer
  var pagingInfo = PagingInfoRPC()
  let pb = initProtoBuffer(buffer)

  var pageSize: uint64
  discard ?pb.getField(1, pageSize)
  pagingInfo.pageSize = pageSize

  var cursorBuffer: seq[byte]
  discard ?pb.getField(2, cursorBuffer)
  pagingInfo.cursor = ?PagingIndexRPC.decode(cursorBuffer)

  var direction: uint32
  discard ?pb.getField(3, direction)
  pagingInfo.direction = PagingDirectionRPC(direction)

  ok(pagingInfo) 


## Wire protocol

proc encode*(filter: HistoryContentFilterRPC): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, filter.contentTopic)
  pb.finish3()

  pb

proc decode*(T: type HistoryContentFilterRPC, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var contentTopic: ContentTopic
  discard ?pb.getField(1, contentTopic)

  ok(HistoryContentFilterRPC(contentTopic: contentTopic))


proc encode*(query: HistoryQueryRPC): ProtoBuffer =
  var pb = initProtoBuffer()
  pb.write3(2, query.pubsubTopic)
  
  for filter in query.contentFilters:
    pb.write3(3, filter.encode())

  pb.write3(4, query.pagingInfo.encode())
  pb.write3(5, zint64(query.startTime))
  pb.write3(6, zint64(query.endTime))
  pb.finish3()

  pb

proc decode*(T: type HistoryQueryRPC, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryQueryRPC()
  let pb = initProtoBuffer(buffer)

  discard ?pb.getField(2, msg.pubsubTopic)

  var buffs: seq[seq[byte]]
  discard ?pb.getRepeatedField(3, buffs)
  
  for pb in buffs:
    msg.contentFilters.add(? HistoryContentFilterRPC.decode(pb))

  var pagingInfoBuffer: seq[byte]
  discard ?pb.getField(4, pagingInfoBuffer)

  msg.pagingInfo = ?PagingInfoRPC.decode(pagingInfoBuffer)

  var startTime: zint64
  discard ?pb.getField(5, startTime)
  msg.startTime = Timestamp(startTime)

  var endTime: zint64
  discard ?pb.getField(6, endTime)
  msg.endTime = Timestamp(endTime)

  ok(msg)


proc encode*(response: HistoryResponseRPC): ProtoBuffer =
  var pb = initProtoBuffer()

  for msg in response.messages:
    pb.write3(2, msg.encode())

  pb.write3(3, response.pagingInfo.encode())
  pb.write3(4, uint32(ord(response.error)))
  pb.finish3()

  pb

proc decode*(T: type HistoryResponseRPC, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryResponseRPC()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]
  discard ?pb.getRepeatedField(2, messages)

  for pb in messages:
    let message = ?WakuMessage.decode(pb)
    msg.messages.add(message)

  var pagingInfoBuffer: seq[byte]
  discard ?pb.getField(3, pagingInfoBuffer)
  msg.pagingInfo = ?PagingInfoRPC.decode(pagingInfoBuffer)

  var error: uint32
  discard ?pb.getField(4, error)
  msg.error = HistoryResponseErrorRPC.parse(error)

  ok(msg)


proc encode*(rpc: HistoryRPC): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)
  pb.write3(2, rpc.query.encode())
  pb.write3(3, rpc.response.encode())
  pb.finish3()

  pb

proc decode*(T: type HistoryRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = HistoryRPC()
  let pb = initProtoBuffer(buffer)
  discard ?pb.getField(1, rpc.requestId)

  var queryBuffer: seq[byte]
  discard ?pb.getField(2, queryBuffer)
  rpc.query = ?HistoryQueryRPC.decode(queryBuffer)

  var responseBuffer: seq[byte]
  discard ?pb.getField(3, responseBuffer)
  rpc.response = ?HistoryResponseRPC.decode(responseBuffer)

  ok(rpc)
