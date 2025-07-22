import chronicles, std/options, results
import ../waku_conf

logScope:
  topics = "waku conf builder peer exchange"

##################################
## Peer Exchange Config Builder ##
##################################
type PeerExchangeConfBuilder* = object
  strictPeerExchangeFiltering*: bool

proc init*(T: type PeerExchangeConfBuilder): PeerExchangeConfBuilder =
  PeerExchangeConfBuilder()

proc withStrictPeerFiltering*(b: var PeerExchangeConfBuilder, enabled: bool) =
  b.strictPeerExchangeFiltering = enabled

proc build*(b: PeerExchangeConfBuilder): Result[Option[PeerExchangeConf], string] =
  return
    ok(some(PeerExchangeConf(strictPeerExchangeFilter: b.strictPeerExchangeFiltering)))
