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

    minMixPoolSize* {.
        desc: "Number of messages to wait for before sending.",
        defaultValue: 3,
        name: "min-mix-pool-size",
    }: int