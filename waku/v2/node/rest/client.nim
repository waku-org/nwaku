{.push raises: [Defect].}

import presto/client

proc newRestHttpClient*(address: TransportAddress): RestClientRef =
  RestClientRef.new(address, HttpClientScheme.NonSecure)
