

type
  MsgType = enum
    NODE_MANAGEMENT,
    RELAY,
    STORE,
    FILTER,
    ADMIN,
    LIGHT_PUSH

type
  RequestMsg = ref object
    msgType: MsgType
    # content: MsgReqContent
