
import
    std/json

type JsonSignal* = ref object of RootObj
  # https://rfc.vac.dev/spec/36/#jsonsignal-type
  eventType* {.requiresInit.}: string

method `$`*(jsonSignal: JsonSignal): string {.base.} = discard
  # All events should implement this

