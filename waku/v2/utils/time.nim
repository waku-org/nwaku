## Contains types and utilities for timestamps.

{.push raises: [Defect].}

proc getNanosecondTime*(t: float64): int64 = 
  var tns = t*100000000
  return tns

proc getMicrosecondTime*(t: float64): int64 = 
  var tmus = t*1000000
  return tns

proc getMillisecondTime*(t: float64): int64 = 
  var tms = t*1000
  return tms