## Contains types and utilities for timestamps.

{.push raises: [Defect].}

import sqlite3_abi
import chronicles

type Timestamp* = distinct int64 

const TIMESTAMP_TABLE_TYPE* = "INTEGER"

# Timestamp arithmetic
# Safe from signed under- and over-flows
##########################################
# Equality
##########################################
proc `==`*(t1, t2: Timestamp): bool =
  return t1.int64 == t2.int64

proc `==`*(t1: Timestamp, t2: int): bool =
  return t1 == Timestamp(t2)

proc `==`*(t1: int, t2: Timestamp): bool =
  return Timestamp(t1) == t2

proc `==`*(t1: Timestamp, t2: int64): bool =
  return t1 == Timestamp(t2)

proc `==`*(t1: int64, t2: Timestamp): bool =
  return Timestamp(t1) == t2

##########################################
# Lower
##########################################
proc `<`*(t1, t2: Timestamp): bool =
  return t1.int64 < t2.int64

proc `<`*(t1: Timestamp, t2: int): bool =
  return t1 < Timestamp(t2)

proc `<`*(t1: int, t2: Timestamp): bool =
  return Timestamp(t1) < t2

proc `<`*(t1: Timestamp, t2: int64): bool =
  return t1 < Timestamp(t2)

proc `<`*(t1: int64, t2: Timestamp): bool =
  return Timestamp(t1) < t2

##########################################
# Greater
##########################################
proc `>`*(t1, t2: Timestamp): bool =
  return t1.int64 > t2.int64

proc `>`*(t1: Timestamp, t2: int): bool =
  return t1 > Timestamp(t2)

proc `>`*(t1: int, t2: Timestamp): bool =
  return Timestamp(t1) > t2

proc `>`*(t1: Timestamp, t2: int64): bool =
  return t1 > Timestamp(t2)

proc `>`*(t1: int64, t2: Timestamp): bool =
  return Timestamp(t1) > t2

##########################################
# Addition
##########################################
proc `+`*(t1, t2: Timestamp): Timestamp =
  var sum: int64
  # The "and" operator is lazy, that is in x and y, if x is false, y is not evaluated
  # https://nim-lang.org/docs/system.html#and%2Cbool%2Cbool
  # So we don't accidentally trigger under/overflow errors evaluating if conditions
  # We check for over-flows
  if (t2.int64 > 0) and (t1.int64 > (Timestamp.high.int64 - t2.int64)):
    debug "A sum of timestamps over-flowed", t1 = t1.int64, t2 = t2.int64
    sum = Timestamp.high.int64
  # We check for under-flow
  elif (t2.int64 < 0) and (t1.int64 < (Timestamp.low.int64 - t2.int64)):
    debug "A sum of timestamps under-flowed", t1 = t1.int64, t2 = t2.int64
    sum = Timestamp.low.int64
  else:
    sum = t1.int64 + t2.int64
  return Timestamp(sum)

proc `+`*(t1: Timestamp, t2: int): Timestamp =
  return t1 + Timestamp(t2)

proc `+`*(t1: int, t2: Timestamp): Timestamp =
  return Timestamp(t1) + t2

##########################################
# Subtraction
##########################################
proc `-`*(t1, t2: Timestamp): Timestamp =
  var diff: int64
  # The "and" operator is lazy, that is in "x and y", if x is false, y is not evaluated
  # https://nim-lang.org/docs/system.html#and%2Cbool%2Cbool
  # So we don't accidentally trigger under/overflow errors evaluating if conditions
  # We check for under-flows
  if (t2.int64 > 0) and (t1.int64 < (Timestamp.low.int64 + t2.int64)):
    debug "A difference of timestamps under-flowed", t1 = t1.int64, t2 = t2.int64
    diff = Timestamp.low.int64
  # We check for over-flow
  elif (t2.int64 < 0) and (t1.int64 > (Timestamp.high.int64 + t2.int64)):
    debug "A difference of timestamps over-flowed", t1 = t1.int64, t2 = t2.int64
    diff = Timestamp.high.int64
  else:
    diff = t1.int64 - t2.int64
  return Timestamp(diff)

proc `-`*(t1: Timestamp, t2: int): Timestamp =
  return t1 - Timestamp(t2)

proc `-`*(t1: int, t2: Timestamp): Timestamp =
  return Timestamp(t1) - t2

##########################################
# Sign swap
##########################################
proc `-`*(t: Timestamp): Timestamp =
  return Timestamp(0) - t

##########################################
# Time conversions (from seconds)
##########################################
proc getNanosecondTime*[T](timeInSeconds: T): Timestamp = 
  var ns = Timestamp(timeInSeconds.int64 * 1000_000_000.int64)
  return ns

proc getMicrosecondTime*[T](timeInSeconds: T): Timestamp = 
  var us = Timestamp(timeInSeconds.int64 * 1000_000.int64)
  return us

proc getMillisecondTime*[T](timeInSeconds: T): Timestamp = 
  var ms = Timestamp(timeInSeconds.int64 * 1000.int64)
  return ms

proc column_timestamp*(a1: ptr sqlite3_stmt, iCol: cint): int64 =
  return sqlite3_column_int64(a1, iCol)