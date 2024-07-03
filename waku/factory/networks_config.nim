when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

type ClusterConf* = object
  maxMessageSize*: string
  clusterId*: uint16
  rlnRelay*: bool
  rlnRelayEthContractAddress*: string
  rlnRelayChainId*: uint
  rlnRelayDynamic*: bool
  rlnRelayBandwidthThreshold*: int
  rlnEpochSizeSec*: uint64
  rlnRelayUserMessageLimit*: uint64
  pubsubTopics*: seq[string]
  discv5Discovery*: bool
  discv5BootstrapNodes*: seq[string]

# cluster-id=0
# Cluster configuration for the default pubsub topic. Note that it
# overrides existing cli configuration
proc ClusterZeroConf*(T: type ClusterConf): ClusterConf =
  return ClusterConf(
    clusterId: 0,
    pubsubTopics:
      @["/waku/2/default-waku/proto"] # TODO: Add more config such as bootstrap, etc
    ,
  )

# cluster-id=1 (aka The Waku Network)
# Cluster configuration corresponding to The Waku Network. Note that it
# overrides existing cli configuration
proc TheWakuNetworkConf*(T: type ClusterConf): ClusterConf =
  return ClusterConf(
    maxMessageSize: "150KiB",
    clusterId: 1,
    rlnRelay: true,
    rlnRelayEthContractAddress: "0xCB33Aa5B38d79E3D9Fa8B10afF38AA201399a7e3",
    rlnRelayDynamic: true,
    rlnRelayChainId: 11155111,
    rlnRelayBandwidthThreshold: 0,
    rlnEpochSizeSec: 600,
    rlnRelayUserMessageLimit: 20,
    pubsubTopics:
      @[
        "/waku/2/rs/1/0", "/waku/2/rs/1/1", "/waku/2/rs/1/2", "/waku/2/rs/1/3",
        "/waku/2/rs/1/4", "/waku/2/rs/1/5", "/waku/2/rs/1/6", "/waku/2/rs/1/7",
      ],
    discv5Discovery: true,
    discv5BootstrapNodes:
      @[
        "enr:-QESuED0qW1BCmF-oH_ARGPr97Nv767bl_43uoy70vrbah3EaCAdK3Q0iRQ6wkSTTpdrg_dU_NC2ydO8leSlRpBX4pxiAYJpZIJ2NIJpcIRA4VDAim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOTd-h5owwj-cx7xrmbvQKU8CV3Fomfdvcv1MBc-67T5oN0Y3CCdl-DdWRwgiMohXdha3UyDw",
        "enr:-QEkuED9X80QF_jcN9gA2ZRhhmwVEeJnsg_Hyg7IFCTYnZD0BDI7a8HArE61NhJZFwygpHCWkgwSt2vqiABXkBxzIqZBAYJpZIJ2NIJpcIQiQlleim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQPFAS8zz2cg1QQhxMaK8CzkGQ5wdHvPJcrgLzJGOiHpwYN0Y3CCdl-DdWRwgiMohXdha3UyDw",
        "enr:-QEkuEBfEzJm_kigJ2HoSS_RBFJYhKHocGdkhhBr6jSUAWjLdFPp6Pj1l4yiTQp7TGHyu1kC6FyaU573VN8klLsEm-XuAYJpZIJ2NIJpcIQI2SVcim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQZ2XwA2Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS5zYW5kYm94LnN0YXR1cy5pbQYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQOwsS69tgD7u1K50r5-qG5hweuTwa0W26aYPnvivpNlrYN0Y3CCdl-DdWRwgiMohXdha3UyDw",
      ],
  )
