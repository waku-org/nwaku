{.push raises: [Defect].}

import 
  stew/results,
  chronicles
import
  ./message_store,
  ./message_retention_policy

logScope:
  topics = "message_store.sqlite_store.retention_policy.capacity"


const StoreMaxOverflow = 1.3

type 
  # CapacityRetentionPolicy implements auto deletion as follows:
  #  - The sqlite DB will store up to `totalCapacity = capacity` * `StoreMaxOverflow` messages, 
  #    giving an overflowWindow of `capacity * (StoreMaxOverflow - 1) = overflowWindow`.
  #
  #  - In case of an overflow, messages are sorted by `receiverTimestamp` and the oldest ones are 
  #    deleted. The number of messages that get deleted is `(overflowWindow / 2) = deleteWindow`,
  #    bringing the total number of stored messages back to `capacity + (overflowWindow / 2)`. 
  #
  # The rationale for batch deleting is efficiency. We keep half of the overflow window in addition 
  # to `capacity` because we delete the oldest messages with respect to `receiverTimestamp` instead of 
  # `senderTimestamp`. `ReceiverTimestamp` is guaranteed to be set, while senders could omit setting 
  # `senderTimestamp`. However, `receiverTimestamp` can differ from node to node for the same message.
  # So sorting by `receiverTimestamp` might (slightly) prioritize some actually older messages and we 
  # compensate that by keeping half of the overflow window.
  CapacityRetentionPolicy* = ref object of MessageRetentionPolicy
      capacity: int # represents both the number of messages that are persisted in the sqlite DB (excl. the overflow window explained above), and the number of messages that get loaded via `getAll`.
      totalCapacity: int # = capacity * StoreMaxOverflow
      deleteWindow: int # = capacity * (StoreMaxOverflow - 1) / 2; half of the overflow window, the amount of messages deleted when overflow occurs


proc calculateTotalCapacity(capacity: int, overflow: float): int =
  int(float(capacity) * overflow)

proc calculateOverflowWindow(capacity: int, overflow: float): int =
  int(float(capacity) * (overflow - 1))
  
proc calculateDeleteWindow(capacity: int, overflow: float): int =
  calculateOverflowWindow(capacity, overflow) div 2


proc init*(T: type CapacityRetentionPolicy, capacity=StoreDefaultCapacity): T =
  let 
    totalCapacity = calculateTotalCapacity(capacity, StoreMaxOverflow)
    deleteWindow = calculateDeleteWindow(capacity, StoreMaxOverflow)

  CapacityRetentionPolicy(
    capacity: capacity,
    totalCapacity: totalCapacity,
    deleteWindow: deleteWindow
  )

method execute*(p: CapacityRetentionPolicy, store: MessageStore): RetentionPolicyResult[void] =
  let numMessages = ?store.getMessagesCount().mapErr(proc(err: string): string = "failed to get messages count: " & err)

  if numMessages < p.totalCapacity:
    return ok()

  let res = store.deleteOldestMessagesNotWithinLimit(limit=p.capacity + p.deleteWindow)
  if res.isErr(): 
    return err("deleting oldest messages failed: " & res.error())

  ok()