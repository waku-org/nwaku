
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[strutils, options],
  regex,
  stew/results
import
  ./retention_policy_base,
  ./retention_policy/retention_policy_time,
  ./retention_policy/retention_policy_capacity

proc new*(T: type RetentionPolicy,
          retPolicy: string):
          RetentionPolicyResult[Option[RetentionPolicy]] =

  # Validate the retention policy format
  if retPolicy == "" or retPolicy == "none":
    return ok(none(RetentionPolicy))

  const StoreMessageRetentionPolicyRegex = re"^\w+:\w+$"
  if not retPolicy.match(StoreMessageRetentionPolicyRegex):
    return err("invalid 'store message retention policy' format: " & retPolicy)

  # Apply the retention policy, if any
  let rententionPolicyParts = retPolicy.split(":", 1)
  let
    policy = rententionPolicyParts[0]
    policyArgs = rententionPolicyParts[1]

  if policy == "time":
    var retentionTimeSeconds: int64
    try:
      retentionTimeSeconds = parseInt(policyArgs)
    except ValueError:
      return err("invalid time retention policy argument")

    let retPolicy: RetentionPolicy = TimeRetentionPolicy.init(retentionTimeSeconds)
    return ok(some(retPolicy))

  elif policy == "capacity":
    var retentionCapacity: int
    try:
      retentionCapacity = parseInt(policyArgs)
    except ValueError:
      return err("invalid capacity retention policy argument")

    let retPolicy: RetentionPolicy = CapacityRetentionPolicy.init(retentionCapacity)
    return ok(some(retPolicy))

  else:
    return err("unknown retention policy")
