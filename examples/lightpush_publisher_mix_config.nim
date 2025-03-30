import
  confutils/defs


type
  LPMixConf* = object

    destPeerAddr* {.
        desc: "Destination peer address.",
        name: "dp-addr",
    }: string

    destPeerId* {.
        desc: "Destination peer ID.",
        name: "dp-id",
    }: string

    pxAddr* {.
        desc: "Peer exchange address.",
        defaultValue: "localhost:50001",
        name: "px-addr",
    }: string
    pxId* {.
        desc: "Peer exchange ID.",
        defaultValue: "waku-v2-peer-exchange",
        name: "px-id",
    }: string

    port* {.
        desc: "Port to listen on.",
        defaultValue: 50000,
        name: "port",
    }: int

    numMsgs* {.
        desc: "Number of messages to send.",
        defaultValue: 1,
        name: "num-msgs",
    }: int

    msgInterval*{.
        desc: "Interval between messages in milliseconds.",
        defaultValue: 1000,
        name: "msg-interval",
    }: int

    minMixPoolSize* {.
        desc: "Number of messages to wait for before sending.",
        defaultValue: 3,
        name: "min-mix-pool-size",
    }: int