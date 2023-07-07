
import
    std/json
import
    ./json_base_event

type JsonErrorEvent* = ref object of JsonEvent
    message*: string

proc new*(T: type JsonErrorEvent,
          message: string): T =

  return JsonErrorEvent(
            eventType: "error",
            message: message)

method `$`*(jsonError: JsonErrorEvent): string =
  $( %* jsonError )