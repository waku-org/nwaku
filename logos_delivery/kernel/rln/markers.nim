## Strings node core matches on to recognise RLN rejections, whichever backend
## is mounted.

const RlnValidatorErrorMsg* = "RLN validation failed"
  ## The RLN relay validator's rejection error; publish paths look for it to
  ## trigger a proof refresh and a publish retry.

const RlnProofRefreshScheduledMsg* =
  "stale RLN proof suspected; refresh scheduled, retry the publish"
  ## OUT_OF_RLN_PROOF description marker telling callers a background refresh
  ## was scheduled and retrying the publish is worthwhile.
