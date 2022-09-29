## Contains types and utilities for timestamps.
{.push raises: [Defect].}

import 
  metrics,
  std/times

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

template nanosecondTime*(collector: Summary | Histogram, body: untyped) =
  when defined(metrics) and defined(times):
    let start = getTime().toUnixFloat()
    body
    collector.observe(getTime().toUnixFloat() - start)
  else:
    body