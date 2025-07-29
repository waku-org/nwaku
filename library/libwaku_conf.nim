import std/options, waku/factory/waku_conf, waku/factory/conf_builder

type ShardingMode* = enum
  AutoSharding
  StaticSharding

type AutoShadingConf* = object
  numShardsInCluster*: uint16

type NetworkConf* = object
  bootstrapNodes*: seq[string]
  staticStoreNodes*: seq[string]
  clusterId*: uint16
  shardingMode*: ShardingMode
  AutoShardingConf*: Option[AutoShardingConf]

type WakuMode* = enum
  Edge
  Relay

type LibWakuConf* = object
  mode*: WakuMode
  networkConf*: NetworkConf
  storeConfirmation*: bool

proc toWakuConf*(libConf: LibWakuConf): Result[WakuConf, string] =
  let b = WakuConfBuilder.init()
  
  case mode
  of Relay:
    b.withRelayEnabled(true)
    b.filterServiceConf.withEnabled(true)
    b.lightPushServiceConf.withEnabled(true)
    b.withDiscv5Enabled(true)
    b.withPeerExchange(true)

    # Values applied when used as a library - should probably become default values
    b.filterServiceConf.withMaxPeersToServe(20)
    b.withRateLimits(
      @[
        
      ]
    )
nwakuCfg.RateLimits.Filter = &bindingscommon.RateLimit{Volume: 100, Period: 1, TimeUnit: bindingscommon.Second}
		nwakuCfg.RateLimits.Lightpush = &bindingscommon.RateLimit{Volume: 5, Period: 1, TimeUnit: bindingscommon.Second}
    nwakuCfg.RateLimits.PeerExchange = &bindingscommon.RateLimit{Volume: 5, Period: 1, TimeUnit: bindingscommon.Second}


  of Edge:
    return err("Edge mode is not implemented")
  


# 	if !cfg.LightClient {
		nwakuCfg.Discv5Discovery = true
		nwakuCfg.Relay = true
		nwakuCfg.Filter = true
		nwakuCfg.FilterMaxPeersToServe = 20
		nwakuCfg.Lightpush = true
		
	}

	if cfg.EnablePeerExchangeServer {
		nwakuCfg.PeerExchange = true
		
	}