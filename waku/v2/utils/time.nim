## Contains types and utilities for timestamps.
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import 
  std/times,
  metrics

type Timestamp* = int64 

proc getNanosecondTime*[T](timeInSeconds: T): Timestamp = 
  var ns = Timestamp(timeInSeconds.int64 * 1000_000_000.int64)
  return ns

proc getMicrosecondTime*[T](timeInSeconds: T): Timestamp = 
  var us = Timestamp(timeInSeconds.int64 * 1000_000.int64)
  return us

proc getMillisecondTime*[T](timeInSeconds: T): Timestamp = 
  var ms = Timestamp(timeInSeconds.int64 * 1000.int64)
  return ms

proc nowInUnixFloat(): float =
  return getTime().toUnixFloat()

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