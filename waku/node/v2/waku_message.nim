type
  WakuMessage* = object
    payload*: seq[byte]
    contentTopic*: string
