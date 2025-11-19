{.used.}

import testutils/unittests
import chronos
import std/strutils

import waku/waku_core/broker/request_broker

RequestBroker:
  type SimpleResponse = object
    value*: string

  proc signatureFetch*(): Future[Result[SimpleResponse, string]] {.async.}

RequestBroker:
  type KeyedResponse = object
    key*: string
    payload*: string

  proc signatureFetchWithKey*(
    key: string, subKey: int
  ): Future[Result[KeyedResponse, string]] {.async.}

RequestBroker:
  type DualResponse = object
    note*: string
    count*: int

  proc signatureNoInput*(): Future[Result[DualResponse, string]] {.async.}
  proc signatureWithInput*(
    suffix: string
  ): Future[Result[DualResponse, string]] {.async.}

RequestBroker:
  type ImplicitResponse = object
    note*: string

suite "RequestBroker macro":
  test "serves zero-argument providers":
    SimpleResponse.setProvider(
      proc(): Future[Result[SimpleResponse, string]] {.async.} =
        ok(SimpleResponse(value: "hi"))
    )

    let res = waitFor SimpleResponse.request()
    check res.isOk
    check res.value.value == "hi"

    SimpleResponse.clearProvider()

  test "zero-argument request errors when unset":
    let res = waitFor SimpleResponse.request()
    check res.isErr
    check res.error.contains("no zero-arg provider")

  test "serves input-based providers":
    var seen: seq[string] = @[]
    KeyedResponse.setProvider(
      proc(key: string, subKey: int): Future[Result[KeyedResponse, string]] {.async.} =
        seen.add(key)
        ok(KeyedResponse(key: key, payload: key & "-payload+" & $subKey))
    )

    let res = waitFor KeyedResponse.request("topic", 1)
    check res.isOk
    check res.value.key == "topic"
    check res.value.payload == "topic-payload+1"
    check seen == @["topic"]

    KeyedResponse.clearProvider()

  test "catches provider exception":
    KeyedResponse.setProvider(
      proc(key: string, subKey: int): Future[Result[KeyedResponse, string]] {.async.} =
        raise newException(ValueError, "simulated failure")
        ok(KeyedResponse(key: key, payload: ""))
    )

    let res = waitFor KeyedResponse.request("neglected", 11)
    check res.isErr()
    check res.error.contains("simulated failure")

    KeyedResponse.clearProvider()

  test "input request errors when unset":
    let res = waitFor KeyedResponse.request("foo", 2)
    check res.isErr
    check res.error.contains("input signature")

  test "supports both provider types simultaneously":
    DualResponse.setProvider(
      proc(): Future[Result[DualResponse, string]] {.async.} =
        ok(DualResponse(note: "base", count: 1))
    )
    DualResponse.setProvider(
      proc(suffix: string): Future[Result[DualResponse, string]] {.async.} =
        ok(DualResponse(note: "base" & suffix, count: suffix.len))
    )

    let noInput = waitFor DualResponse.request()
    check noInput.isOk
    check noInput.value.note == "base"

    let withInput = waitFor DualResponse.request("-extra")
    check withInput.isOk
    check withInput.value.note == "base-extra"
    check withInput.value.count == 6

    DualResponse.clearProvider()

  test "clearProvider resets both entries":
    DualResponse.setProvider(
      proc(): Future[Result[DualResponse, string]] {.async.} =
        ok(DualResponse(note: "temp", count: 0))
    )
    DualResponse.clearProvider()

    let res = waitFor DualResponse.request()
    check res.isErr

  test "implicit zero-argument provider works by default":
    ImplicitResponse.setProvider(
      proc(): Future[Result[ImplicitResponse, string]] {.async.} =
        ok(ImplicitResponse(note: "auto"))
    )

    let res = waitFor ImplicitResponse.request()
    check res.isOk
    check res.value.note == "auto"

    ImplicitResponse.clearProvider()

  test "implicit zero-argument request errors when unset":
    let res = waitFor ImplicitResponse.request()
    check res.isErr
    check res.error.contains("no zero-arg provider")
