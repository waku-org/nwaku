import 
  chronos
    

type RetryStrategy* = object
  shouldRetry*: bool
  retryDelay*: Duration
  retryCount*: uint

proc new*(T: type RetryStrategy): RetryStrategy =
  return RetryStrategy(
    shouldRetry: true,
    retryDelay: 1000.millis,
    retryCount: 3
  )


template retryWrapper*(res: auto,
                       retryStrategy: RetryStrategy,
                       errStr: string,
                       body: untyped): auto =
  var retryCount = retryStrategy.retryCount
  var shouldRetry = retryStrategy.shouldRetry
  var exceptionMessage = ""

  while shouldRetry and retryCount > 0:
    try:
      res = body
      shouldRetry = false
    except:
      retryCount -= 1
      exceptionMessage = getCurrentExceptionMsg()
      await sleepAsync(retryStrategy.retryDelay)
  if shouldRetry:
    raise newException(CatchableError, errStr & ": " & exceptionMessage)
