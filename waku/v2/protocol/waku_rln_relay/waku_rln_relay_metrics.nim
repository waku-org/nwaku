{.push raises: [Defect].}

import
  chronicles,
  chronos,
  metrics,
  metrics/chronos_httpserver,
  waku_rln_relay_constants,
  ../../utils/collector

export metrics

logScope:
  topics = "waku-rln-relay.metrics"

func generateBucketsForHistogram*(length: int): seq[float64] =
  ## Generate a custom set of 5 buckets for a given length
  let numberOfBuckets = 5
  let stepSize = length / numberOfBuckets
  var buckets: seq[float64]
  for i in 1..numberOfBuckets:
    buckets.add(stepSize * i.toFloat())
  return buckets

declarePublicCounter(waku_rln_messages_total, "number of messages published on the rln content topic")
declarePublicCounter(waku_rln_spam_messages_total, "number of spam messages detected")
declarePublicCounter(waku_rln_invalid_messages_total, "number of invalid messages detected", ["type"])
# This metric will be useful in detecting the index of the root in the acceptable window of roots
declarePublicHistogram(identifier = waku_rln_valid_messages_total, 
  help = "number of valid messages with their roots tracked", 
  buckets = generateBucketsForHistogram(AcceptableRootWindowSize))
declarePublicCounter(waku_rln_errors_total, "number of errors detected while operating the rln relay", ["type"])
declarePublicCounter(waku_rln_proof_verification_total, "number of times the rln proofs are verified")

# Timing metrics
declarePublicGauge(waku_rln_proof_verification_duration_seconds, "time taken to verify a proof")
declarePublicGauge(waku_rln_relay_mounting_duration_seconds, "time taken to mount the waku rln relay")
declarePublicGauge(waku_rln_proof_generation_duration_seconds, "time taken to generate a proof")
declarePublicGauge(waku_rln_registration_duration_seconds, "time taken to register to a rln membership set")
declarePublicGauge(waku_rln_instance_creation_duration_seconds, "time taken to create an rln instance")
declarePublicGauge(waku_rln_membership_insertion_duration_seconds, "time taken to insert a new member into the local merkle tree")
declarePublicGauge(waku_rln_membership_credentials_import_duration_seconds, "time taken to import membership credentials")

type
  RLNMetricsLogger = proc() {.gcsafe, raises: [Defect].}

proc getRlnMetricsLogger*(): RLNMetricsLogger =
  var logMetrics: RLNMetricsLogger

  var cumulativeErrors = 0.float64
  var cumulativeMessages = 0.float64
  var cumulativeSpamMessages = 0.float64
  var cumulativeInvalidMessages = 0.float64
  var cumulativeValidMessages = 0.float64
  var cumulativeProofs = 0.float64

  logMetrics = proc() =
    {.gcsafe.}:

      let freshErrorCount = parseAndAccumulate(waku_rln_errors_total,
                                               cumulativeErrors)
      let freshMsgCount = parseAndAccumulate(waku_rln_messages_total,
                                             cumulativeMessages)
      let freshSpamCount = parseAndAccumulate(waku_rln_spam_messages_total,
                                              cumulativeSpamMessages)
      let freshInvalidMsgCount = parseAndAccumulate(waku_rln_invalid_messages_total,
                                                    cumulativeInvalidMessages)
      let freshValidMsgCount = parseAndAccumulate(waku_rln_valid_messages_total,
                                                  cumulativeValidMessages)
      let freshProofCount = parseAndAccumulate(waku_rln_proof_verification_total,
                                               cumulativeProofs)

      
      info "Total messages", count = freshMsgCount
      info "Total spam messages", count = freshSpamCount
      info "Total invalid messages", count = freshInvalidMsgCount
      info "Total valid messages", count = freshValidMsgCount
      info "Total errors", count = freshErrorCount
      info "Total proofs verified", count = freshProofCount
  return logMetrics
  
