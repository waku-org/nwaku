when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sets, tables, strutils, sequtils, options, strformat],
  chronos/timer as chtimer,
  chronicles,
  results

import ./tester_message

type
  StatHelper = object
    prevIndex: uint32
    prevArrivedAt: Moment
    lostIndices: HashSet[uint32]
    seenIndices: HashSet[uint32]
    maxIndex: uint32

  Statistics* = object
    allMessageCount*: uint32
    receivedMessages*: uint32
    misorderCount*: uint32
    lateCount*: uint32
    duplicateCount*: uint32
    minLatency*: Duration
    maxLatency*: Duration
    cummulativeLatency: Duration
    helper: StatHelper

  PerPeerStatistics* = Table[string, Statistics]

func `$`*(a: Duration): string {.inline.} =
  ## Original stringify implementation from chronos/timer.nim is not capable of printing 0ns
  ## Returns string representation of Duration ``a`` as nanoseconds value.

  if a.isZero:
    return "0ns"

  return chtimer.`$`(a)

proc init*(T: type Statistics, expectedMessageCount: int = 1000): T =
  result.helper.prevIndex = 0
  result.helper.maxIndex = 0
  result.helper.seenIndices.init(expectedMessageCount)
  result.minLatency = nanos(0)
  result.maxLatency = nanos(0)
  result.cummulativeLatency = nanos(0)
  return result

proc addMessage*(self: var Statistics, msg: ProtocolTesterMessage) =
  if self.allMessageCount == 0:
    self.allMessageCount = msg.count
  elif self.allMessageCount != msg.count:
    warn "Message count mismatch at message",
      index = msg.index, expected = self.allMessageCount, got = msg.count

  if not self.helper.seenIndices.contains(msg.index):
    self.helper.seenIndices.incl(msg.index)
  else:
    inc(self.duplicateCount)
    warn "Duplicate message", index = msg.index
    ## just do not count into stats
    return

  ## detect misorder arrival and possible lost messages
  if self.helper.prevIndex + 1 < msg.index:
    inc(self.misorderCount)
    warn "Misordered message arrival",
      index = msg.index, expected = self.helper.prevIndex + 1

    ## collect possible lost message indicies
    for idx in self.helper.prevIndex + 1 ..< msg.index:
      self.helper.lostIndices.incl(idx)
  elif self.helper.prevIndex > msg.index:
    inc(self.lateCount)
    warn "Late message arrival", index = msg.index, expected = self.helper.prevIndex + 1
  else:
    ## may remove late arrival
    self.helper.lostIndices.excl(msg.index)

  ## calculate latency
  let currentArrivedAt = Moment.now()

  let delaySincePrevArrived: Duration = currentArrivedAt - self.helper.prevArrivedAt

  let expectedDelay: Duration = nanos(msg.sincePrev)

  var latency: Duration

  # if we have any latency...
  if expectedDelay > delaySincePrevArrived:
    latency = delaySincePrevArrived - expectedDelay
    if self.minLatency.isZero or (latency < self.minLatency and latency > nanos(0)):
      self.minLatency = latency
    if latency > self.maxLatency:
      self.maxLatency = latency
    self.cummulativeLatency += latency
  else:
    warn "Negative latency detected",
      index = msg.index, expected = expectedDelay, actual = delaySincePrevArrived

  self.helper.maxIndex = max(self.helper.maxIndex, msg.index)
  self.helper.prevIndex = msg.index
  self.helper.prevArrivedAt = currentArrivedAt
  inc(self.receivedMessages)

proc addMessage*(
    self: var PerPeerStatistics, peerId: string, msg: ProtocolTesterMessage
) =
  if not self.contains(peerId):
    self[peerId] = Statistics.init()

  discard catch:
    self[peerId].addMessage(msg)

proc lossCount*(self: Statistics): uint32 =
  self.helper.maxIndex - self.receivedMessages

proc averageLatency*(self: Statistics): Duration =
  if self.receivedMessages == 0:
    return nanos(0)
  return self.cummulativeLatency div self.receivedMessages

proc echoStat*(self: Statistics) =
  let printable = catch:
    """*------------------------------------------------------------------------------------------*
|  Expected  |  Received  |   Target   |    Loss    |  Misorder  |    Late    |  Duplicate |
|{self.helper.maxIndex:>11} |{self.receivedMessages:>11} |{self.allMessageCount:>11} |{self.lossCount():>11} |{self.misorderCount:>11} |{self.lateCount:>11} |{self.duplicateCount:>11} |
*------------------------------------------------------------------------------------------*
| Latency stat:                                                                            |
|    avg latency: {$self.averageLatency():<73}|
|    min latency: {$self.maxLatency:<73}|
|    max latency: {$self.minLatency:<73}|
*------------------------------------------------------------------------------------------*""".fmt()

  if printable.isErr():
    echo "Error while printing statistics: " & printable.error().msg
  else:
    echo printable.get()

proc jsonStat*(self: Statistics): string =
  let json = catch:
    """{{"expected":{self.helper.maxIndex},
         "received": {self.receivedMessages},
         "target": {self.allMessageCount},
         "loss": {self.lossCount()},
         "misorder": {self.misorderCount},
         "late": {self.lateCount},
         "duplicate": {self.duplicateCount},
         "latency":
           {{"avg": "{self.averageLatency()}",
             "min": "{self.minLatency}",
             "max": "{self.maxLatency}"
           }}
     }}""".fmt()
  if json.isErr:
    return "{\"result:\": \"" & json.error.msg & "\"}"

  return json.get()

proc echoStats*(self: var PerPeerStatistics) =
  for peerId, stats in self.pairs:
    let peerLine = catch:
      "Receiver statistics from peer {peerId}".fmt()
    if peerLine.isErr:
      echo "Error while printing statistics"
    else:
      echo peerLine.get()
      stats.echoStat()

proc jsonStats*(self: PerPeerStatistics): string =
  try:
    #!fmt: off
    var json = "{\"statistics\": ["
    var first = true
    for peerId, stats in self.pairs:
      if first:
        first = false
      else:
        json.add(", ")
      json.add("{{\"sender\": \"{peerId}\", \"stat\":".fmt())
      json.add(stats.jsonStat())
      json.add("}")
    json.add("]}")
    return json
    #!fmt: on
  except CatchableError:
    return
      "{\"result:\": \"Error while generating json stats: " & getCurrentExceptionMsg() &
      "\"}"

proc checkIfAllMessagesReceived*(self: PerPeerStatistics): bool =
  # if there are no peers have sent messages, assume we just have started.
  if self.len == 0:
    return false

  for stat in self.values:
    if (stat.allMessageCount == 0 and stat.receivedMessages == 0) or
        stat.receivedMessages < stat.allMessageCount:
      return false

  return true
