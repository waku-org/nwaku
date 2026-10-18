{.push raises: [].}

import results, chronos
import logos_delivery/kernel/archive/driver

type RetentionPolicyResult*[T] = Result[T, string]

type RetentionPolicy* = ref object of RootObj

method execute*(
    p: RetentionPolicy, store: ArchiveDriver
): Future[RetentionPolicyResult[void]] {.base, async.} =
  discard

method `$`*(p: RetentionPolicy): string {.base, gcsafe.} =
  "unknown retention policy"
