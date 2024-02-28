when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronos

import
  ../topics,
  ../message

type FilterPushHandler* = proc(pubsubTopic: PubsubTopic,
                               message: WakuMessage,
                               msgId: seq[byte]) {.async, gcsafe, closure.}
