{.used.}

import testutils/unittests
import chronos
import std/sequtils

import waku/waku_core/broker/multi_request_broker

MultiRequestBroker:
  type NoArgResponse = object
    label*: string

  proc signatureFetch*(): Future[Result[NoArgResponse, string]] {.async.}

MultiRequestBroker:
  type ArgResponse = object
    id*: string

  proc signatureFetch*(
    suffix: string, numsuffix: int
  ): Future[Result[ArgResponse, string]] {.async.}

MultiRequestBroker:
  type DualResponse = object
    note*: string
    suffix*: string

  proc signatureBase*(): Future[Result[DualResponse, string]] {.async.}
  proc signatureWithInput*(
    suffix: string
  ): Future[Result[DualResponse, string]] {.async.}

suite "MultiRequestBroker":
  test "aggregates zero-argument providers":
    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        ok(NoArgResponse(label: "one"))
    )

    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        discard catch:
          await sleepAsync(1.milliseconds)
        ok(NoArgResponse(label: "two"))
    )

    let responses = waitFor NoArgResponse.request()
    check responses.get().len == 2
    check responses.get().anyIt(it.label == "one")
    check responses.get().anyIt(it.label == "two")

    NoArgResponse.clearProviders()

  test "aggregates argument providers":
    discard ArgResponse.setProvider(
      proc(suffix: string, num: int): Future[Result[ArgResponse, string]] {.async.} =
        ok(ArgResponse(id: suffix & "-a-" & $num))
    )

    discard ArgResponse.setProvider(
      proc(suffix: string, num: int): Future[Result[ArgResponse, string]] {.async.} =
        ok(ArgResponse(id: suffix & "-b-" & $num))
    )

    let keyed = waitFor ArgResponse.request("topic", 1)
    check keyed.get().len == 2
    check keyed.get().anyIt(it.id == "topic-a-1")
    check keyed.get().anyIt(it.id == "topic-b-1")

    ArgResponse.clearProviders()

  test "clearProviders resets both provider lists":
    discard DualResponse.setProvider(
      proc(): Future[Result[DualResponse, string]] {.async.} =
        ok(DualResponse(note: "base", suffix: ""))
    )

    discard DualResponse.setProvider(
      proc(suffix: string): Future[Result[DualResponse, string]] {.async.} =
        ok(DualResponse(note: "base" & suffix, suffix: suffix))
    )

    let noArgs = waitFor DualResponse.request()
    check noArgs.get().len == 1

    let param = waitFor DualResponse.request("-extra")
    check param.get().len == 1
    check param.get()[0].suffix == "-extra"

    DualResponse.clearProviders()

    let emptyNoArgs = waitFor DualResponse.request()
    check emptyNoArgs.get().len == 0

    let emptyWithArgs = waitFor DualResponse.request("-extra")
    check emptyWithArgs.get().len == 0

  test "request returns empty seq when no providers registered":
    let empty = waitFor NoArgResponse.request()
    check empty.get().len == 0

  test "failed providers will fail the request":
    NoArgResponse.clearProviders()
    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        err(Result[NoArgResponse, string], "boom")
    )

    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        ok(NoArgResponse(label: "survivor"))
    )

    let filtered = waitFor NoArgResponse.request()
    check filtered.isErr()

    NoArgResponse.clearProviders()

  test "deduplicates identical zero-argument providers":
    NoArgResponse.clearProviders()
    var invocations = 0
    let sharedHandler = proc(): Future[Result[NoArgResponse, string]] {.async.} =
      inc invocations
      ok(NoArgResponse(label: "dup"))

    let first = NoArgResponse.setProvider(sharedHandler)
    let second = NoArgResponse.setProvider(sharedHandler)

    check first.get().id == second.get().id
    check first.get().kind == second.get().kind

    let dupResponses = waitFor NoArgResponse.request()
    check dupResponses.get().len == 1
    check invocations == 1

    NoArgResponse.clearProviders()

  test "removeProvider deletes registered handlers":
    var removedCalled = false
    var keptCalled = false

    let removable = NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        removedCalled = true
        ok(NoArgResponse(label: "removed"))
    )

    discard NoArgResponse.setProvider(
      proc(): Future[Result[NoArgResponse, string]] {.async.} =
        keptCalled = true
        ok(NoArgResponse(label: "kept"))
    )

    NoArgResponse.removeProvider(removable.get())

    let afterRemoval = (waitFor NoArgResponse.request()).valueOr:
      assert false, "request failed"
      @[]
    check afterRemoval.len == 1
    check afterRemoval[0].label == "kept"
    check not removedCalled
    check keptCalled

    NoArgResponse.clearProviders()

  test "removeProvider works for argument signatures":
    var invoked: seq[string] = @[]

    discard ArgResponse.setProvider(
      proc(suffix: string, num: int): Future[Result[ArgResponse, string]] {.async.} =
        invoked.add("first" & suffix)
        ok(ArgResponse(id: suffix & "-one-" & $num))
    )

    let handle = ArgResponse.setProvider(
      proc(suffix: string, num: int): Future[Result[ArgResponse, string]] {.async.} =
        invoked.add("second" & suffix)
        ok(ArgResponse(id: suffix & "-two-" & $num))
    )

    ArgResponse.removeProvider(handle.get())

    let single = (waitFor ArgResponse.request("topic", 1)).valueOr:
      assert false, "request failed"
      @[]
    check single.len == 1
    check single[0].id == "topic-one-1"
    check invoked == @["firsttopic"]

    ArgResponse.clearProviders()
