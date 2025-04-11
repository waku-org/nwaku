import confutils/defs

type LPMixConf* = object
  destPeerAddr* {.desc: "Destination peer address with peerId.", name: "dp-addr".}:
    string

  pxAddr* {.desc: "Peer exchange address with peerId.", name: "px-addr".}: string

  port* {.desc: "Port to listen on.", defaultValue: 50000, name: "port".}: int

  numMsgs* {.desc: "Number of messages to send.", defaultValue: 1, name: "num-msgs".}:
    int

  msgInterval* {.
    desc: "Interval between messages in milliseconds.",
    defaultValue: 1000,
    name: "msg-interval"
  .}: int

  minMixPoolSize* {.
    desc: "Number of messages to wait for before sending.",
    defaultValue: 3,
    name: "min-mix-pool-size"
  .}: int

  withoutMix* {.
    desc: "Do not use mix for publishing.", defaultValue: false, name: "without-mix"
  .}: bool
