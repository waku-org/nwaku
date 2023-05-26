when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

type PgAsyncPoolOptions* = object
  ## Database connection pool options
  minConnections*: int
  maxConnections*: int

func init*(T: type PgAsyncPoolOptions,
           minConnections: Positive = 1,
           maxConnections: Positive = 5): T =
  if minConnections > maxConnections:
    raise newException(Defect, "maxConnections must be greater or equal to minConnections")

  PgAsyncPoolOptions(
    minConnections: minConnections,
    maxConnections: maxConnections,
  )