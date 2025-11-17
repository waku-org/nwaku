import chronos
import std/sequtils
import testutils/unittests

import waku/waku_core/broker/event_broker

EventBroker:
  type SampleEvent = object
    value*: int
    label*: string

EventBroker:
  type BinaryEvent = object
    flag*: bool

template waitForListeners() =
  waitFor sleepAsync(1.milliseconds)

suite "EventBroker":
  test "delivers events to all listeners":
    var seen: seq[(int, string)] = @[]

    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async.} =
        seen.add((evt.value, evt.label))
    )

    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async.} =
        seen.add((evt.value * 2, evt.label & "!"))
    )

    let evt = SampleEvent(value: 5, label: "hi")
    SampleEvent.emit(evt)
    waitForListeners()

    check seen.len == 2
    check seen.anyIt(it == (5, "hi"))
    check seen.anyIt(it == (10, "hi!"))

  test "forget removes a single listener":
    var counter = 0

    let handleA = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async.} =
        inc counter
    )

    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async.} =
        inc(counter, 2)
    )

    SampleEvent.forget(handleA)
    let eventVal = SampleEvent(value: 1, label: "one")
    SampleEvent.emit(eventVal)
    waitForListeners()
    check counter == 2

  test "forgetAll clears every listener":
    var triggered = false

    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async.} =
        triggered = true
    )
    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async.} =
        discard
    )

    SampleEventBroker.forgetAll()
    let clearedEvent = SampleEvent(value: 42, label: "noop")
    SampleEvent.emit(clearedEvent)
    waitForListeners()
    check not triggered

    let freshHandle = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async.} =
        discard
    )
    check freshHandle.id > 0'u64
    SampleEvent.forget(freshHandle)

  test "broker helpers operate via typedesc":
    var toggles: seq[bool] = @[]

    discard BinaryEventBroker.listen(
      proc(evt: BinaryEvent): Future[void] {.async.} =
        toggles.add(evt.flag)
    )

    BinaryEvent(flag: true).emit()
    waitForListeners()
    let binaryEvent = BinaryEvent(flag: false)
    BinaryEvent.emit(binaryEvent)
    waitForListeners()

    check toggles == @[true, false]
