
import
  std/json

type
  ResultType* = enum
    OK
    ERROR

type
  InterThreadResponse* = object
    result*: ResultType
    message*: string # only used to give feedback when an error occurs

proc `$`*(self: InterThreadResponse): string =
  return $( %* self )
