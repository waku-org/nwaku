
## This module is aimed to handle the creation and truncation of partition tables
## in order to limit the space occupied in disk by the database.
##
## The created partitions are referenced by the 'storedAt' field.
##

import
  std/[times, deques],
  strutils
import
  chronos,
  chronicles
import
  ../../../waku_core/time,
  ../../driver

logScope:
  topics = "waku archive partitions_manager"

## The Timestamp range is measured in seconds
type TimeRange* = tuple[beginning: Timestamp, `end`: Timestamp]

type
  Partition = object
    name: string
    timeRange: TimeRange

  PartitionManager* = ref object
    partitions: Deque[Partition] # FIFO of partition table names. The first is the oldest partition

proc new*(T: type PartitionManager): T =
  return PartitionManager()

# proc getTimeRangeFromPartitionName*(partitionName: string): ArchiveDriverResult[TimeRange] =
#   ## Given a partition name, this proc extracts a tuple containing the timestamp range

#   if not partitionName.contains("messages_"):
#     return err("partition name should contain 'messages_'")

#   let onlyDatesString = partitionName.replace("messages_", "")

#   let timesAsString = onlyDatesString.split("_")
#   if timesAsString.len != 2:
#     return err("expected two timestamps in partition name, but found: " & partitionName)

#   var ret: TimeRange
#   try:
#     ret.beginning = Timestamp(parseInt(timesAsString[0]))
#   except ValueError:
#     return err("invalid beginning timestamp: " & getCurrentExceptionMsg())

#   try:
#     ret.`end` = Timestamp(parseInt(timesAsString[1]))
#   except ValueError:
#     return err("invalid end timestamp: " & getCurrentExceptionMsg())

#   return ok(ret)

proc isCurrentPartitionTheLastOne*(self: PartitionManager): Result[bool, string] =
  ## Returns 'true' is the current partition is the last created one, i.e the newest,
  ## 'false' otherwise
  if self.partitions.len == 0:
    return err("There are no partitions")

  let mostRecentRange = self.partitions.peekLast.timeRange
  let timeOfInterest = now().toTime().toUnix()

  return ok(mostRecentRange.beginning <= timeOfInterest and
            timeOfInterest < mostRecentRange.`end`)

proc getPartitionNameFromDateTime*(self: PartitionManager,
                                   dateTimeOfInterest: DateTime):
                                   Result[string, string] =
  ## Returns the partition name that might store a message containing the passed timestamp.
  ## In order words, it simply returns the partition name which contains the given timestamp.

  if self.partitions.len == 0:
    return err("There are no partitions")

  let timeOfInterest = dateTimeOfInterest.toTime()
  for partition in self.partitions:
    let timeRange = partition.timeRange

    let beginning = times.fromUnix(timeRange.beginning)
    let `end` = times.fromUnix(timeRange.`end`)

    if beginning <= timeOfInterest and timeOfInterest < `end`:
      return ok(partition.name)

  return err("Could'nt find a partition table for given time: " & $timeOfInterest.toUnix())

proc getOldestPartitionName*(self: PartitionManager): string =
  let oldestPartition = self.partitions.peekFirst
  return oldestPartition.name

proc addPartition*(self: PartitionManager,
                   partitionName: string,
                   beginning: Timestamp,
                   `end`: Timestamp) =
  ## The Timestamp is stored in seconds, unix epoch
  self.partitions.addLast(Partition(
                                name: partitionName,
                                timeRange: (beginning, `end`)))

proc removeOldestPartitionName*(self: PartitionManager) =
  discard self.partitions.popFirst()

