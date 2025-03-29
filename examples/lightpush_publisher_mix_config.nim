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