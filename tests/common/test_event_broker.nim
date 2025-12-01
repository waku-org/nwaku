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

EventBroker:
  type RefEvent = ref object
    payload*: seq[int]

template waitForListeners() =
  waitFor sleepAsync(1.milliseconds)

suite "EventBroker":
  test "delivers events to all listeners":
    var seen: seq[(int, string)] = @[]

    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        seen.add((evt.value, evt.label))
    )

    discard SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        seen.add((evt.value * 2, evt.label & "!"))
    )

    let evt = SampleEvent(value: 5, label: "hi")
    SampleEvent.emit(evt)
    waitForListeners()

    check seen.len == 2
    check seen.anyIt(it == (5, "hi"))
    check seen.anyIt(it == (10, "hi!"))

    SampleEvent.dropAllListeners()

  test "forget removes a single listener":
    var counter = 0

    let handleA = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        inc counter
    )

    let handleB = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        inc(counter, 2)
    )

    SampleEvent.dropListener(handleA.get())
    let eventVal = SampleEvent(value: 1, label: "one")
    SampleEvent.emit(eventVal)
    waitForListeners()
    check counter == 2

    SampleEvent.dropAllListeners()

  test "forgetAll clears every listener":
    var triggered = false

    let handle1 = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        triggered = true
    )
    let handle2 = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        discard
    )

    SampleEvent.dropAllListeners()
    SampleEvent.emit(42, "noop")
    SampleEvent.emit(label = "noop", value = 42)
    waitForListeners()
    check not triggered

    let freshHandle = SampleEvent.listen(
      proc(evt: SampleEvent): Future[void] {.async: (raises: []).} =
        discard
    )
    check freshHandle.get().id > 0'u64
    SampleEvent.dropListener(freshHandle.get())

  test "broker helpers operate via typedesc":
    var toggles: seq[bool] = @[]

    let handle = BinaryEvent.listen(
      proc(evt: BinaryEvent): Future[void] {.async: (raises: []).} =
        toggles.add(evt.flag)
    )

    BinaryEvent(flag: true).emit()
    waitForListeners()
    let binaryEvent = BinaryEvent(flag: false)
    BinaryEvent.emit(binaryEvent)
    waitForListeners()

    check toggles == @[true, false]
    BinaryEvent.dropAllListeners()

  test "ref typed event":
    var counter: int = 0

    let handle = RefEvent.listen(
      proc(evt: RefEvent): Future[void] {.async: (raises: []).} =
        for n in evt.payload:
          counter += n
    )

    RefEvent(payload: @[1, 2, 3]).emit()
    waitForListeners()
    RefEvent.emit(payload = @[4, 5, 6])
    waitForListeners()

    check counter == 21 # 1+2+3 + 4+5+6
    RefEvent.dropAllListeners()
