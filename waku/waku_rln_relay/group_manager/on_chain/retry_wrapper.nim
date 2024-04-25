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
    retryStrategy: RetryStrategy,
    errStr: string,
    errCallback: OnFatalErrorHandler,
    body: untyped,
): auto =
  var retryCount = retryStrategy.retryCount
  var shouldRetry = retryStrategy.shouldRetry
  var exceptionMessage = ""

  while shouldRetry and retryCount > 0:
    try:
      return await fut
    except:
      retryCount -= 1
      exceptionMessage = getCurrentExceptionMsg()
      await sleepAsync(retryStrategy.retryDelay)
  if shouldRetry:
    errCallback(errStr & ": " & exceptionMessage)
    return
