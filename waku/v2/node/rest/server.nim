{.push raises: [Defect].}

import
  std/[os, times],
  std/typetraits,
  stew/[byteutils, io2],
  stew/shims/net,
  chronicles, chronos,
  metrics, metrics/chronos_httpserver,
  bearssl,
  presto


proc getRouter(allowedOrigin: Option[string]): RestRouter =
  # TODO: Review this `validate` method. Check in nim-presto what is this used for.
  proc validate(pattern: string, value: string): int =
    ## This is rough validation procedure which should be simple and fast,
    ## because it will be used for query routing.
    if pattern.startsWith("{") and pattern.endsWith("}"): 0
    else: 1

  RestRouter.init(validate, allowedOrigin = allowedOrigin)


type RestServerConf* = object 
      cacheSize*: Natural ## \
        ## The maximum number of recently accessed states that are kept in \
        ## memory. Speeds up requests obtaining information for consecutive  
        ## slots or epochs.

      cacheTtl*: Natural ## \
        ## The number of seconds to keep recently accessed states in memory

      requestTimeout*: Natural ## \
        ## The number of seconds to wait until complete REST request will be received

      maxRequestBodySize*: Natural ## \
        ## Maximum size of REST request body (kilobytes)

      maxRequestHeadersSize*: Natural ## \
        ## Maximum size of REST request headers (kilobytes)

proc default(T: type RestServerConf): RestServerConf =
  RestServerConf(
      cacheSize: 3,
      cacheTtl: 60,
      requestTimeout: 0,
      maxRequestBodySize: 16_384,
      maxRequestHeadersSize: 64
  )


template init*(T: type RestServerRef,
              ip: ValidIpAddress, port: Port,
              allowedOrigin: Option[string],
              config: Option[RestServerConf]): T =
  let address = initTAddress(ip, port)
  let serverFlags = {
    HttpServerFlags.QueryCommaSeparatedArray,
    HttpServerFlags.NotifyDisconnect
  }
  
  let conf = if config.isSome: config.get() 
             else: RestServerConf.default()

  let 
    headersTimeout = if conf.requestTimeout == 0: chronos.InfiniteDuration
                     else: seconds(int64(conf.requestTimeout))
    maxHeadersSize = conf.maxRequestHeadersSize * 1024
    maxRequestBodySize = conf.maxRequestBodySize * 1024

  let router = getRouter(allowedOrigin)
  let res = RestServerRef.new(
    router, 
    address, 
    serverFlags = serverFlags,
    httpHeadersTimeout = headersTimeout,
    maxHeadersSize = maxHeadersSize,
    maxRequestBodySize = maxRequestBodySize
  )

  if res.isErr():
    notice "Rest server could not be started", address = $address, reason = res.error()
    nil
  else:
    notice "Starting REST HTTP server", url = "http://" & $ip & ":" & $port & "/"
    res.get()
