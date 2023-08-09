when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/times,
  metrics

type Timestamp* = int64 # A nanosecond precision timestamp

proc getNanosecondTime*[T: SomeNumber](timeInSeconds: T): Timestamp =
  var ns = Timestamp(timeInSeconds * 1_000_000_000.T)
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
