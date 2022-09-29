import
  metrics,
  std/times

export metrics

declarePublicCounter(waku_rln_messages_total, "number of messages published on the rln content topic")
declarePublicCounter(waku_rln_spam_messages_total, "number of spam messages detected")
declarePublicCounter(waku_rln_invalid_messages_total, "number of invalid messages detected", ["type"])
# This metric will be useful in detecting the index of the root in the acceptable window of roots
declarePublicCounter(waku_rln_valid_messages_total, "number of valid messages with their roots tracked", ["index"])
declarePublicCounter(waku_rln_errors_total, "number of errors detected while operating the rln relay", ["type"])
declarePublicCounter(waku_rln_proof_verification_total, "number of times the rln proofs are verified")

# Timing metrics
declarePublicHistogram(waku_rln_proof_verification_duration_seconds, "time taken to verify a proof")
declarePublicHistogram(waku_rln_relay_mounting_duration_seconds, "time taken to mount the waku rln relay")
declarePublicHistogram(waku_rln_proof_generation_duration_seconds, "time taken to generate a proof")
declarePublicHistogram(waku_rln_registration_duration_seconds, "time taken to register to a rln membership set")
declarePublicHistogram(waku_rln_instance_creation_duration_seconds, "time taken to create an rln instance")
declarePublicHistogram(waku_rln_membership_insertion_duration_seconds, "time taken to insert a new member into the local merkle tree")
declarePublicHistogram(waku_rln_membership_credentials_import_duration_seconds, "time taken to import membership credentials")

template granularTime*(collector: Summary | Histogram, body: untyped) =
  when defined(metrics) and defined(times):
    let start = getTime().toUnixFloat()
    body
    collector.observe(getTime().toUnixFloat() - start)
  else:
    body
