## Contains types and utilities for timestamps.

{.push raises: [Defect].}

import sqlite3_abi

type Timestamp* = int64 

const TIMESTAMP_TABLE_TYPE* = "INTEGER"

proc getNanosecondTime*[T](timeInSeconds: T): Timestamp = 
  var ns = Timestamp(timeInSeconds*1000_000_000)
  return ns

proc getMicrosecondTime*[T](timeInSeconds: T): Timestamp = 
  var us = Timestamp(timeInSeconds*1000_000)
  return us

proc getMillisecondTime*[T](timeInSeconds: T): Timestamp = 
  var ms = Timestamp(timeInSeconds*1000)
  return ms

proc column_timestamp*(a1: ptr sqlite3_stmt, iCol: cint): int64 =
  return sqlite3_column_int64(a1, iCol)