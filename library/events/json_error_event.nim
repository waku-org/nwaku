
import
    std/json
import
    json_signal_event

type JsonErrorEvent* = ref object of JsonSignal
    message*: string

proc new*(T: type JsonErrorEvent,
          message: string): T =
  return JsonErrorEvent(
            eventType: "error",
            message: message)

method `$`*(jsonError: JsonErrorEvent): string =
  $( %* jsonError )