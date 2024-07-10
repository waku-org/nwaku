import ../../../common/error_handling
import chronos
import results

type RetryStrategy* = object
  shouldRetry*: bool
  retryDelay*: Duration
  retryCount*: uint

proc new*(T: type RetryStrategy): RetryStrategy =
  return RetryStrategy(shouldRetry: true, retryDelay: 4000.millis, retryCount: 15)

template retryWrapper*(
    res: auto,
    retryStrategy: RetryStrategy,
    errStr: string,
    errCallback: OnFatalErrorHandler,
    body: untyped,
): auto =
  if errCallback == nil:
    raise newException(CatchableError, "Ensure that the errCallback is set")
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
    errCallback(errStr & ": " & exceptionMessage)
    return
