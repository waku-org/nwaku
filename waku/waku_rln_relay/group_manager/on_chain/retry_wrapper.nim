import ../../../common/error_handling
import chronos
import results

type RetryStrategy* = object
  shouldRetry*: bool
  retryDelay*: Duration
  retryCount*: uint

proc new*(T: type RetryStrategy): RetryStrategy =
  return RetryStrategy(shouldRetry: true, retryDelay: 1000.millis, retryCount: 3)

proc retryWrapper*[T](
    retryStrategy: RetryStrategy,
    errStr: string,
    errCallback: OnFatalErrorHandler = nil,
    fut: Future[T],
): Future[T] {.async.} =
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
    if errCallback == nil:
      raise newException(
        CatchableError, errStr & " errCallback == nil: " & exceptionMessage
      )
    else:
      errCallback(errStr & ": " & exceptionMessage)
      return
