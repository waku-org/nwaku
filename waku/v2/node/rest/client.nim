when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import presto/client

proc newRestHttpClient*(address: TransportAddress): RestClientRef =
  RestClientRef.new(address, HttpClientScheme.NonSecure)
