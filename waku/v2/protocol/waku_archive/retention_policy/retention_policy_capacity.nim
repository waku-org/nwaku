when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  stew/results,
  chronicles
import
  ../driver,
  ../retention_policy

logScope:
  topics = "waku archive retention_policy"


const DefaultCapacity*: int = 25_000

const MaxOverflow = 1.3

type
  # CapacityRetentionPolicy implements auto deletion as follows:
  #  - The sqlite DB will driver up to `totalCapacity = capacity` * `MaxOverflow` messages,
  #    giving an overflowWindow of `capacity * (MaxOverflow - 1) = overflowWindow`.
  #
  #  - In case of an overflow, messages are sorted by `receiverTimestamp` and the oldest ones are
  #    deleted. The number of messages that get deleted is `(overflowWindow / 2) = deleteWindow`,
  #    bringing the total number of driverd messages back to `capacity + (overflowWindow / 2)`.
  #
  # The rationale for batch deleting is efficiency. We keep half of the overflow window in addition
  # to `capacity` because we delete the oldest messages with respect to `receiverTimestamp` instead of
  # `senderTimestamp`. `ReceiverTimestamp` is guaranteed to be set, while senders could omit setting
  # `senderTimestamp`. However, `receiverTimestamp` can differ from node to node for the same message.
  # So sorting by `receiverTimestamp` might (slightly) prioritize some actually older messages and we
  # compensate that by keeping half of the overflow window.
  CapacityRetentionPolicy* = ref object of RetentionPolicy
      capacity: int # represents both the number of messages that are persisted in the sqlite DB (excl. the overflow window explained above), and the number of messages that get loaded via `getAll`.
      totalCapacity: int # = capacity * MaxOverflow
      deleteWindow: int # = capacity * (MaxOverflow - 1) / 2; half of the overflow window, the amount of messages deleted when overflow occurs


proc calculateTotalCapacity(capacity: int, overflow: float): int =
  int(float(capacity) * overflow)

proc calculateOverflowWindow(capacity: int, overflow: float): int =
  int(float(capacity) * (overflow - 1))

proc calculateDeleteWindow(capacity: int, overflow: float): int =
  calculateOverflowWindow(capacity, overflow) div 2


proc init*(T: type CapacityRetentionPolicy, capacity=DefaultCapacity): T =
  let
    totalCapacity = calculateTotalCapacity(capacity, MaxOverflow)
    deleteWindow = calculateDeleteWindow(capacity, MaxOverflow)

  CapacityRetentionPolicy(
    capacity: capacity,
    totalCapacity: totalCapacity,
    deleteWindow: deleteWindow
  )

method execute*(p: CapacityRetentionPolicy, driver: ArchiveDriver): RetentionPolicyResult[void] =
  let numMessages = ?driver.getMessagesCount().mapErr(proc(err: string): string = "failed to get messages count: " & err)

  if numMessages < p.totalCapacity:
    return ok()

  let res = driver.deleteOldestMessagesNotWithinLimit(limit=p.capacity + p.deleteWindow)
  if res.isErr():
    return err("deleting oldest messages failed: " & res.error())

  ok()
