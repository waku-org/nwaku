{.push raises: [Defect].}

import
  stew/results
import
  ../../sqlite


type RetentionPolicyResult*[T] = Result[T, string]

type MessageRetentionPolicy* = ref object of RootObj


method execute*(p: MessageRetentionPolicy, db: SqliteDatabase): RetentionPolicyResult[void] {.base.} = discard