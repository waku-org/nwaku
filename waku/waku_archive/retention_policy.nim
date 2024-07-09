{.push raises: [].}

import results, chronos
import ./driver

type RetentionPolicyResult*[T] = Result[T, string]

type RetentionPolicy* = ref object of RootObj

method execute*(
    p: RetentionPolicy, store: ArchiveDriver
): Future[RetentionPolicyResult[void]] {.base, async.} =
  discard
