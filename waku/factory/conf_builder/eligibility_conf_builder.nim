import chronicles, std/options, results
import ../waku_conf
import eth/common as eth_common

logScope:
  topics = "waku conf builder eligibility"

type EligibilityConfBuilder* = object
  enabled*: Option[bool]
  receiverAddress*: Option[string]
  paymentAmountWei*: Option[uint32]
  ethClientUrls*: Option[seq[string]]

proc init*(T: type EligibilityConfBuilder): EligibilityConfBuilder =
  EligibilityConfBuilder()

proc withEnabled*(b: var EligibilityConfBuilder, enabled: bool) =
  b.enabled = some(enabled)

proc withReceiverAddress*(b: var EligibilityConfBuilder, receiverAddress: string) =
  b.receiverAddress = some(receiverAddress)

proc withPaymentAmountWei*(b: var EligibilityConfBuilder, amount: uint32) =
  b.paymentAmountWei = some(amount)

proc withEthClientUrls*(b: var EligibilityConfBuilder, urls: seq[string]) =
  b.ethClientUrls = some(urls)

proc build*(b: EligibilityConfBuilder): Result[Option[EligibilityConf], string] =
  if not b.enabled.get(false):
    debug "eligibility: EligibilityConf not enabled"
    return ok(none(EligibilityConf))

  # Validation
  if b.receiverAddress.isNone() or b.paymentAmountWei.isNone():
    debug "eligibility: EligibilityConf validation failed - missing address or amount"
    return err("Eligibility: receiver address and payment amount must be specified")

  # FIXME: add validation check that receiver address is validly formed

  if b.paymentAmountWei.get() == 0:
    debug "eligibility: EligibilityConf validation failed - payment amount is zero"
    return err("Eligibility: payment amount must be above zero")

  # FIXME: how to reuse Eth RPC URL from RLN (?) config?
  let urls = b.ethClientUrls.get(@[])
  if urls.len == 0:
    debug "eligibility: EligibilityConf validation failed - no eth rpc urls"
    return err("Eligibility: eligibility-eth-client-address is not specified")

  debug "eligibility: EligibilityConf created"
  return ok(
    some(
      EligibilityConf(
        enabled: true,
        receiverAddress: b.receiverAddress.get(),
        paymentAmountWei: b.paymentAmountWei.get(),
        ethClientUrls: urls,
      )
    )
  )
