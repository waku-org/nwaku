##
## This file is aimed to attend the requests that come directly
## from the 'self' node. It is expected to attend the store requests that
## come from REST-store endpoint when those requests don't indicate
## any store-peer address.
##
## Notice that the REST-store requests normally assume that the REST
## server is acting as a store-client. In this module, we allow that
## such REST-store node can act as store-server as well by retrieving
## its own stored messages. The typical use case for that is when
## using `nwaku-compose`, which spawn a Waku node connected to a local
## database, and the user is interested in retrieving the messages
## stored by that local store node.
##

import stew/results, chronos, chronicles
import ./protocol, ./common

proc handleSelfStoreRequest*(
    self: WakuStore, histQuery: HistoryQuery
): Future[WakuStoreResult[HistoryResponse]] {.async.} =
  ## Handles the store requests made by the node to itself.
  ## Normally used in REST-store requests

  try:
    let resp: HistoryResponse = (await self.queryHandler(histQuery)).valueOr:
      return err("error in handleSelfStoreRequest: " & $error)

    return WakuStoreResult[HistoryResponse].ok(resp)
  except Exception:
    return err("exception in handleSelfStoreRequest: " & getCurrentExceptionMsg())
