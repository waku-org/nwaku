import chronicles, std/options, results
import ../waku_conf

logScope:
  topics = "waku conf builder reputation"

type ReputationConfBuilder* = object
  enabled*: Option[bool]

proc init*(T: type ReputationConfBuilder): ReputationConfBuilder =
  ReputationConfBuilder()

proc withEnabled*(b: var ReputationConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc build*(b: ReputationConfBuilder): Result[Option[ReputationConf], string] =
  if not b.enabled.get(false):
    debug "reputation: ReputationConf not enabled"
    return ok(none(ReputationConf))

  debug "reputation: ReputationConf created"
  return ok(
    some(
      ReputationConf(
        enabled: true
      )
    )
  )