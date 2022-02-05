## Contains types and utilities for timestamps.

{.push raises: [Defect].}

proc getNanosecondTime*(t: float64): int64 = 
  var tns = int64(t*100000000)
  return tns

proc getMicrosecondTime*(t: float64): int64 = 
  var tmus = int64(t*1000000)
  return tmus

proc getMillisecondTime*(t: float64): int64 = 
  var tms = int64(t*1000)
  return tms