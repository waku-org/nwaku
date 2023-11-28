
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[strutils, options],
  regex,
  stew/results
import
  ../retention_policy,
  ./retention_policy_time,
  ./retention_policy_capacity,
  ./retention_policy_size

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

  elif policy == "size":
    var retentionSize: string
    retentionSize = policyArgs
    
    # captures the size unit such as GB or MB
    let sizeUnit = retentionSize.substr(retentionSize.len-2)
    # captures the string type number data of the size provided  
    let sizeQuantityStr = retentionSize.substr(0,retentionSize.len-3)
    # to hold the numeric value data of size
    var inptSizeQuantity: float
    var sizeQuantity: int64
    
    if sizeUnit in ["gb", "Gb", "GB", "gB"]:
      # parse the actual value into integer type var
      try:
        inptSizeQuantity = parseFloat(sizeQuantityStr)
      except ValueError:
        return err("invalid size retention policy argument: " & getCurrentExceptionMsg())
      # GB data is converted into bytes for uniform processing
      sizeQuantity =  int64(inptSizeQuantity * 1024.0 * 1024.0 * 1024.0)
    elif sizeUnit in ["mb", "Mb", "MB", "mB"]:
      try:
        inptSizeQuantity = parseFloat(sizeQuantityStr)
        # MB data is converted into bytes for uniform processing
        sizeQuantity = int64(inptSizeQuantity * 1024.0 * 1024.0)
      except ValueError:
        return err("invalid size retention policy argument")
    else:
      return err ("""invalid size retention value unit: expected "Mb" or "Gb" but got """ & sizeUnit )
    
    if sizeQuantity <= 0:
          return err("invalid size retention policy argument: a non-zero value is required")

    let retPolicy: RetentionPolicy = SizeRetentionPolicy.init(sizeQuantity)
    return ok(some(retPolicy))

  else:
    return err("unknown retention policy")

