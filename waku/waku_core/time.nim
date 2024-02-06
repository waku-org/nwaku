when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/times, metrics

type Timestamp* = int64 # A nanosecond precision timestamp

proc getNanosecondTime*(timeInSeconds: int64 | float64): Timestamp =
  let ns = Timestamp(timeInSeconds * 1_000_000_000)
  return ns

proc nowInUnixFloat(): float =
  return getTime().toUnixFloat()

proc getNowInNanosecondTime*(): Timestamp =
  return getNanosecondTime(nowInUnixFloat())

template nanosecondTime*(collector: Summary | Histogram, body: untyped) =
  when defined(metrics):
    let start = nowInUnixFloat()
    body
    collector.observe(nowInUnixFloat() - start)
  else:
    body

template nanosecondTime*(collector: Gauge, body: untyped) =
  when defined(metrics):
    let start = nowInUnixFloat()
    body
    metrics.set(collector, nowInUnixFloat() - start)
  else:
    body

proc timestampInSeconds*(time: Timestamp): Timestamp =
  let timeStr = $time
  var timestamp: Timestamp = time

  if timeStr.len() > 16:
    timestamp = Timestamp(time div Timestamp(1_000_000_000))
  elif timeStr.len() < 16 and timeStr.len() > 13:
    timestamp = Timestamp(time div Timestamp(1_000_000))
  elif timeStr.len() > 10:
    timestamp = Timestamp(time div Timestamp(1000))
  return timestamp
