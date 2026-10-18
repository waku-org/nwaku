## Core identifier types for the Reliable Channel API.

import std/hashes
import results, chronos
import logos_delivery/api/types as api_types

import sds
import message as sds_message
import types/persistence as sds_persistence_types

export sds_message, sds_persistence_types
export api_types

type ChannelId* = SdsChannelID

type ChannelCryptoFn* = proc(payload: seq[byte]): Future[Result[seq[byte], string]] {.
  async: (raises: []), closure
.}

proc hash*(r: RequestId): Hash =
  ## Allows `RequestId` to be used as a `Table` key.
  hash(string(r))
