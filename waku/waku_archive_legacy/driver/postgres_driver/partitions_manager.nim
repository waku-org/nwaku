## This module is aimed to handle the creation and truncation of partition tables
## in order to limit the space occupied in disk by the database.
##
## The created partitions are referenced by the 'storedAt' field.
##

import std/deques
import chronos, chronicles

logScope:
  topics = "waku archive partitions_manager"

## The time range has seconds resolution
type TimeRange* = tuple[beginning: int64, `end`: int64]

type
  Partition = object
    name: string
    timeRange: TimeRange

  PartitionManager* = ref object
    partitions: Deque[Partition]
      # FIFO of partition table names. The first is the oldest partition

proc new*(T: type PartitionManager): T =
  return PartitionManager()

proc getPartitionFromDateTime*(
    self: PartitionManager, targetMoment: int64
): Result[Partition, string] =
  ## Returns the partition name that might store a message containing the passed timestamp.
  ## In order words, it simply returns the partition name which contains the given timestamp.
  ## targetMoment - represents the time of interest, measured in seconds since epoch.

  if self.partitions.len == 0:
    return err("There are no partitions")

  for partition in self.partitions:
    let timeRange = partition.timeRange

    let beginning = timeRange.beginning
    let `end` = timeRange.`end`

    if beginning <= targetMoment and targetMoment < `end`:
      return ok(partition)

  return err("Couldn't find a partition table for given time: " & $targetMoment)

proc getNewestPartition*(self: PartitionManager): Result[Partition, string] =
  if self.partitions.len == 0:
    return err("there are no partitions allocated")

  let newestPartition = self.partitions.peekLast
  return ok(newestPartition)

proc getOldestPartition*(self: PartitionManager): Result[Partition, string] =
  if self.partitions.len == 0:
    return err("there are no partitions allocated")

  let oldestPartition = self.partitions.peekFirst
  return ok(oldestPartition)

proc addPartitionInfo*(
    self: PartitionManager, partitionName: string, beginning: int64, `end`: int64
) =
  ## The given partition range has seconds resolution.
  ## We just store information of the new added partition merely to keep track of it.
  let partitionInfo = Partition(name: partitionName, timeRange: (beginning, `end`))
  trace "Adding partition info"
  self.partitions.addLast(partitionInfo)

proc removeOldestPartitionName*(self: PartitionManager) =
  ## Simply removed the partition from the tracked/known partitions queue.
  ## Just remove it and ignore it.
  discard self.partitions.popFirst()

proc isEmpty*(self: PartitionManager): bool =
  return self.partitions.len == 0

proc getLastMoment*(partition: Partition): int64 =
  ## Considering the time range covered by the partition, this
  ## returns the `end` time (number of seconds since epoch) of such range.
  let lastTimeInSec = partition.timeRange.`end`
  return lastTimeInSec

proc getPartitionStartTimeInNanosec*(partition: Partition): int64 =
  return partition.timeRange.beginning * 1_000_000_000

proc containsMoment*(partition: Partition, time: int64): bool =
  ## Returns true if the given moment is contained within the partition window,
  ## 'false' otherwise.
  ## time - number of seconds since epoch
  if partition.timeRange.beginning <= time and time < partition.timeRange.`end`:
    return true

  return false

proc getName*(partition: Partition): string =
  return partition.name

func `==`*(a, b: Partition): bool {.inline.} =
  return a.name == b.name
