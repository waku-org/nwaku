when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

type ClusterConf* = object
  maxMessageSize*: string
  clusterId*: uint32
  rlnRelay*: bool
  rlnRelayEthContractAddress*: string
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
    clusterId: 0.uint32,
    pubsubTopics: @["/waku/2/rs/0/5"] # TODO: Add more config such as bootstrap, etc
    ,
  )

# cluster-id=1 (aka The Waku Network)
# Cluster configuration corresponding to The Waku Network. Note that it
# overrides existing cli configuration
proc TheWakuNetworkConf*(T: type ClusterConf): ClusterConf =
  return ClusterConf(
    maxMessageSize: "150KiB",
    clusterId: 1.uint32,
    rlnRelay: true,
    rlnRelayEthContractAddress: "0xF471d71E9b1455bBF4b85d475afb9BB0954A29c4",
    rlnRelayDynamic: true,
    rlnRelayBandwidthThreshold: 0,
    rlnEpochSizeSec: 1,
    # parameter to be defined with rln_v2
    rlnRelayUserMessageLimit: 1,
    pubsubTopics:
      @[
        "/waku/2/rs/1/0", "/waku/2/rs/1/1", "/waku/2/rs/1/2", "/waku/2/rs/1/3",
        "/waku/2/rs/1/4", "/waku/2/rs/1/5", "/waku/2/rs/1/6", "/waku/2/rs/1/7",
      ],
    discv5Discovery: true,
    discv5BootstrapNodes:
      @[
        "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Ugl_r25UHQJ3f1rIRrpzxJXSMaJe4yk1XFSAYJpZIJ2NIJpcISygI2rim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQJATXRSRSUyTw_QLB6H_U3oziVQgNRgrXpK7wp2AMyNxYN0Y3CCdl-DdWRwgiMohXdha3UyDw",
        "enr:-QEkuECnZ3IbVAgkOzv-QLnKC4dRKAPRY80m1-R7G8jZ7yfT3ipEfBrhKN7ARcQgQ-vg-h40AQzyvAkPYlHPaFKk6u9uAYJpZIJ2NIJpcIQiEAFDim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQMIJwesBVgUiBCi8yiXGx7RWylBQkYm1U9dvEy-neLG2YN0Y3CCdl-DdWRwgiMohXdha3UyDw",
        "enr:-QEkuEDzQyIAhs-CgBHIrJqtBv3EY1uP1Psrc-y8yJKsmxW7dh3DNcq2ergMUWSFVcJNlfcgBeVsFPkgd_QopRIiCV2pAYJpZIJ2NIJpcIQI2ttrim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAZ2XwA2Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQJIN4qwz3v4r2Q8Bv8zZD0eqBcKw6bdLvdkV7-JLjqIj4N0Y3CCdl-DdWRwgiMohXdha3UyDw",
      ],
  )
