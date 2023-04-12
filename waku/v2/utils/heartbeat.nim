when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import sequtils
import chronos, chronicles

# Taken from: https://github.com/status-im/nim-libp2p/blob/master/libp2p/utils/heartbeat.nim

template heartbeat*(name: string, interval: Duration, body: untyped): untyped =
  var nextHeartbeat = Moment.now()
  while true:
    body

    nextHeartbeat += interval
    let now = Moment.now()
    if nextHeartbeat < now:
      let
        delay = now - nextHeartbeat
        itv = interval
      if delay > itv:
        info "Missed multiple heartbeats", heartbeat = name,
          delay = delay, hinterval = itv
      else:
        debug "Missed heartbeat", heartbeat = name,
          delay = delay, hinterval = itv
      nextHeartbeat = now + itv
    await sleepAsync(nextHeartbeat - now)
