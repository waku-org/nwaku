import system, std/json, ./json_base_event

type JsonWakuNotRespondingEvent* = ref object of JsonEvent

proc new*(T: type JsonWakuNotRespondingEvent): T =
  return JsonWakuNotRespondingEvent(eventType: "waku_not_responding")

method `$`*(jsonConnectionChangeEvent: JsonWakuNotRespondingEvent): string =
  $(%*jsonConnectionChangeEvent)
