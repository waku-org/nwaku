{.push raises: [Defect].}

import
  nimcrypto/hash,
  libp2p/protobuf/minprotobuf,
  libp2p/varint
import
  ../waku_message,
  ../../utils/protobuf,
  ../../utils/pagination,
  ../../utils/time,
  ./rpc


proc encode*(index: Index): ProtoBuffer =
  ## Encode an Index object into a ProtoBuffer
  ## returns the resultant ProtoBuffer

  var output = initProtoBuffer()
  output.write3(1, index.digest.data)
  output.write3(2, zint64(index.receiverTime))
  output.write3(3, zint64(index.senderTime))
  output.write3(4, index.pubsubTopic)
  output.finish3()

  return output

proc init*(T: type Index, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns an Index object out of buffer
  var index = Index()
  let pb = initProtoBuffer(buffer)

  var data: seq[byte]
  discard ?pb.getField(1, data)

  # create digest from data
  index.digest = MDigest[256]()
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

  return ok(index) 


proc encode*(pinfo: PagingInfo): ProtoBuffer =
  ## Encodes a PagingInfo object into a ProtoBuffer
  ## returns the resultant ProtoBuffer

  var output = initProtoBuffer()
  output.write3(1, pinfo.pageSize)
  output.write3(2, pinfo.cursor.encode())
  output.write3(3, uint32(ord(pinfo.direction)))
  output.finish3()

  return output

proc init*(T: type PagingInfo, buffer: seq[byte]): ProtoResult[T] =
  ## creates and returns a PagingInfo object out of buffer
  var pagingInfo = PagingInfo()
  let pb = initProtoBuffer(buffer)

  var pageSize: uint64
  discard ?pb.getField(1, pageSize)
  pagingInfo.pageSize = pageSize

  var cursorBuffer: seq[byte]
  discard ?pb.getField(2, cursorBuffer)
  pagingInfo.cursor = ?Index.init(cursorBuffer)

  var direction: uint32
  discard ?pb.getField(3, direction)
  pagingInfo.direction = PagingDirection(direction)

  return ok(pagingInfo) 


proc encode*(filter: HistoryContentFilter): ProtoBuffer =
  var output = initProtoBuffer()
  output.write3(1, filter.contentTopic)
  output.finish3()
  return output

proc init*(T: type HistoryContentFilter, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var contentTopic: ContentTopic
  discard ?pb.getField(1, contentTopic)

  ok(HistoryContentFilter(contentTopic: contentTopic))


proc encode*(query: HistoryQuery): ProtoBuffer =
  var output = initProtoBuffer()
  output.write3(2, query.pubsubTopic)
  
  for filter in query.contentFilters:
    output.write3(3, filter.encode())

  output.write3(4, query.pagingInfo.encode())
  output.write3(5, zint64(query.startTime))
  output.write3(6, zint64(query.endTime))
  output.finish3()

  return output

proc init*(T: type HistoryQuery, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryQuery()
  let pb = initProtoBuffer(buffer)

  discard ?pb.getField(2, msg.pubsubTopic)

  var buffs: seq[seq[byte]]
  discard ?pb.getRepeatedField(3, buffs)
  
  for buf in buffs:
    msg.contentFilters.add(? HistoryContentFilter.init(buf))

  var pagingInfoBuffer: seq[byte]
  discard ?pb.getField(4, pagingInfoBuffer)

  msg.pagingInfo = ?PagingInfo.init(pagingInfoBuffer)

  var startTime: zint64
  discard ?pb.getField(5, startTime)
  msg.startTime = Timestamp(startTime)

  var endTime: zint64
  discard ?pb.getField(6, endTime)
  msg.endTime = Timestamp(endTime)

  return ok(msg)


proc encode*(response: HistoryResponse): ProtoBuffer =
  var output = initProtoBuffer()

  for msg in response.messages:
    output.write3(2, msg.encode())

  output.write3(3, response.pagingInfo.encode())
  output.write3(4, uint32(ord(response.error)))
  output.finish3()

  return output

proc init*(T: type HistoryResponse, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryResponse()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]
  discard ?pb.getRepeatedField(2, messages)

  for buf in messages:
    let message = ?WakuMessage.init(buf)
    msg.messages.add(message)

  var pagingInfoBuffer: seq[byte]
  discard ?pb.getField(3, pagingInfoBuffer)
  msg.pagingInfo = ?PagingInfo.init(pagingInfoBuffer)

  var error: uint32
  discard ?pb.getField(4, error)
  msg.error = HistoryResponseError(error)

  return ok(msg)


proc encode*(rpc: HistoryRPC): ProtoBuffer =
  var output = initProtoBuffer()

  output.write3(1, rpc.requestId)
  output.write3(2, rpc.query.encode())
  output.write3(3, rpc.response.encode())

  output.finish3()

  return output

proc init*(T: type HistoryRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = HistoryRPC()
  let pb = initProtoBuffer(buffer)
  discard ?pb.getField(1, rpc.requestId)

  var queryBuffer: seq[byte]
  discard ?pb.getField(2, queryBuffer)
  rpc.query = ?HistoryQuery.init(queryBuffer)

  var responseBuffer: seq[byte]
  discard ?pb.getField(3, responseBuffer)
  rpc.response = ?HistoryResponse.init(responseBuffer)

  return ok(rpc)

