when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options, sugar, sequtils], chronos, libp2p/peerId
import ../waku_core, ../waku_archive, ../waku_store/[client, common], ../waku_sync

type
  TransferCallback* = proc(
    hashes: seq[WakuMessageHash], peerId: PeerId
  ): Future[Result[void, string]] {.async: (raises: []), closure.}

  PruneCallback* = proc(
    startTime: Timestamp, endTime: Timestamp, cursor = none(WakuMessageHash)
  ): Future[
    Result[(seq[(WakuMessageHash, Timestamp)], Option[WakuMessageHash]), string]
  ] {.async: (raises: []), closure.}

# Procs called by wakunode and then passed to WakuStoreSync.new

proc transferHandler*(
    wakuSync: WakuSync, wakuArchive: WakuArchive, wakuStoreClient: WakuStoreClient
): TransferCallback =
  return proc(
      hashes: seq[WakuMessageHash], peerId: PeerId
  ): Future[Result[void, string]] {.async: (raises: []), closure.} =
    var query = StoreQueryRequest()
    query.includeData = true
    query.messageHashes = hashes
    query.paginationLimit = some(uint64(100))

    while true:
      let catchable = catch:
        await wakuStoreClient.query(query, peerId)

      if catchable.isErr():
        return err("store client error: " & catchable.error.msg)

      let res = catchable.get()
      let response = res.valueOr:
        return err("store client error: " & $error)

      query.paginationCursor = response.paginationCursor

      for kv in response.messages:
        let handleRes = catch:
          await wakuArchive.handleMessage(kv.pubsubTopic.get(), kv.message.get())

        if handleRes.isErr():
          #error "message transfer failed", error = handleRes.error.msg
          # Messages can be synced next time since they are not added to storage yet.
          continue

        wakuSync.ingessMessage(kv.pubsubTopic.get(), kv.message.get())

      if query.paginationCursor.isNone():
        break

    return ok()

proc pruningHandler*(wakuArchive: WakuArchive): PruneCallback =
  return proc(
      pruneStart: Timestamp, pruneStop: Timestamp, cursor: Option[WakuMessageHash]
  ): Future[
      Result[(seq[(WakuMessageHash, Timestamp)], Option[WakuMessageHash]), string]
  ] {.async: (raises: []), closure.} =
    let archiveCursor =
      if cursor.isSome():
        some(ArchiveCursor(hash: cursor.get()))
      else:
        none(ArchiveCursor)

    let query = ArchiveQuery(
      includeData: true,
      cursor: archiveCursor,
      startTime: some(pruneStart),
      endTime: some(pruneStop),
      pageSize: 100,
    )

    let catchable = catch:
      await wakuArchive.findMessages(query)

    if catchable.isErr():
      return err("archive error: " & catchable.error.msg)

    let res = catchable.get()
    let response = res.valueOr:
      return err("archive error: " & $error)

    let elements = collect(newSeq):
      for (hash, msg) in response.hashes.zip(response.messages):
        (hash, msg.timestamp)

    let cursor =
      if response.cursor.isNone():
        none(WakuMessageHash)
      else:
        some(response.cursor.get().hash)

    return ok((elements, cursor))
