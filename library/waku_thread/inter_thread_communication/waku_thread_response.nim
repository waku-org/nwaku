## This file contains the base message response type that will be handled.
## The response will be created from the Waku Thread and processed in
## the main thread.

import std/json, results
import ../../alloc

type ResponseType {.pure.} = enum
  OK
  ERR

type InterThreadResponse* = object
  respType: ResponseType
  content: cstring

proc createShared*(
    T: type InterThreadResponse, res: Result[string, string]
): ptr type T =
  ## Converts a `Result[string, string]` into a `ptr InterThreadResponse`
  ## so that it can be transfered to another thread in a safe way.

  var ret = createShared(T)
  if res.isOk():
    let value = res.get()
    ret[].respType = ResponseType.OK
    ret[].content = value.alloc()
  else:
    let error = res.error
    ret[].respType = ResponseType.ERR
    ret[].content = res.error.alloc()
  return ret

proc process*(
    T: type InterThreadResponse, resp: ptr InterThreadResponse
): Result[string, string] =
  ## Converts the received `ptr InterThreadResponse` into a
  ## `Result[string, string]`. Notice that the response is expected to be
  ## allocated from the Waku Thread and deallocated by the main thread.

  defer:
    deallocShared(resp[].content)
    deallocShared(resp)

  case resp[].respType
  of OK:
    return ok($resp[].content)
  of ERR:
    return err($resp[].content)
